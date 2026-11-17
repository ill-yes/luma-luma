#!/usr/bin/env python3
"""Create resumable GitHub releases for manually dispatched Luma Luma builds."""

import argparse
from dataclasses import dataclass
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from release_metadata import (
    ReleaseError,
    compare_commits,
    published_release_for_commit,
    published_tag_commit,
    require_newer_candidate,
    stable_releases,
    tag_commit,
    version_key,
)

RETRY_DELAYS = (0, 1, 2, 4)


@dataclass(frozen=True)
class ReleaseContext:
    repository: str
    commit: str
    run_id: str
    run_number: str
    version: str

    def __post_init__(self):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", self.repository):
            raise ReleaseError("Invalid GitHub repository")
        if not re.fullmatch(r"[0-9a-f]{40}", self.commit):
            raise ReleaseError("The release commit must be a full Git SHA")
        if not re.fullmatch(r"[1-9][0-9]*", self.run_id):
            raise ReleaseError("Invalid GitHub workflow run ID")
        if not re.fullmatch(r"[1-9][0-9]*", self.run_number):
            raise ReleaseError("The workflow run number must be a positive integer")
        version_key(self.version)

    @classmethod
    def from_environment(cls):
        if os.environ.get("GITHUB_REF") != "refs/heads/main":
            raise ReleaseError("Luma Luma releases must be dispatched from main")
        names = ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_NUMBER", "RELEASE_VERSION")
        try:
            return cls(*(os.environ[name] for name in names))
        except KeyError as error:
            raise ReleaseError(f"Missing environment variable {error.args[0]}") from error

    @property
    def tag(self):
        return f"v{self.version}"

    @property
    def disk_images(self):
        return {
            architecture: f"LumaLuma-{self.version}-macos-{architecture}.dmg"
            for architecture in ("arm64", "x86_64")
        }

    @property
    def asset_names(self):
        return tuple(name for image in self.disk_images.values() for name in (image, f"{image}.sha256"))

    @property
    def marker(self):
        return {"run_id": self.run_id, "commit": self.commit, "version": self.version}

    @property
    def url(self):
        return f"https://github.com/{self.repository}/releases/tag/{self.tag}"


class GitHub:
    def __init__(self, repository):
        self.repository = repository
        self.prefix = f"repos/{repository}"

    def _run(self, args, payload=None, allow_missing=False, binary=False, *, operation):
        try:
            result = subprocess.run(
                ["gh", *args], input=payload, capture_output=True,
                text=not binary, check=False,
            )
        except OSError as error:
            raise ReleaseError(f"Could not start GitHub CLI for {operation}") from error
        if result.returncode:
            error_text = result.stderr.decode(errors="replace") if binary else result.stderr
            failure = re.search(r"\bHTTP ([1-5][0-9]{2})\b", error_text)
            status = failure[1] if failure else None
            if allow_missing and status == "404":
                return None
            detail = f"HTTP {status}" if status else f"gh exit {result.returncode}"
            raise ReleaseError(f"GitHub {operation} failed ({detail})")
        return result.stdout

    def api(self, method, path, payload=None, allow_missing=False):
        args = ["api", path, "--method", method]
        encoded = None
        if payload is not None:
            args.extend(["--input", "-"])
            encoded = json.dumps(payload)
        output = self._run(args, encoded, allow_missing, operation=f"{method} {path.split('?')[0]}")
        if output is None:
            return None
        return json.loads(output) if output.strip() else None

    def releases(self):
        output = self._run(
            ["api", f"{self.prefix}/releases?per_page=100", "--paginate", "--slurp"],
            operation="list releases",
        )
        return [release for page in json.loads(output) for release in page]

    def download(self, asset_id):
        return self._run([
            "api", f"{self.prefix}/releases/assets/{asset_id}",
            "--header", "Accept: application/octet-stream",
        ], binary=True, operation=f"download release asset {asset_id}")

    def download_artifact(self, artifact_id):
        return self._run([
            "api", f"{self.prefix}/actions/artifacts/{artifact_id}/zip", "--method", "GET",
        ], binary=True, operation=f"download workflow artifact {artifact_id}")

    def upload(self, release_id, path):
        from urllib.parse import quote
        endpoint = (
            f"https://uploads.github.com/{self.prefix}/releases/{release_id}/assets"
            f"?name={quote(path.name, safe='')}"
        )
        output = self._run([
            "api", endpoint, "--method", "POST", "--header",
            "Content-Type: application/octet-stream", "--input", str(path),
        ], operation=f"upload release asset {path.name}")
        return json.loads(output)


def verify_checksum(name, image, checksum):
    try:
        checksum_text = checksum.decode("ascii")
    except UnicodeDecodeError as error:
        raise ReleaseError(f"The checksum for {name} must contain ASCII text") from error
    match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)(?:\r?\n)?", checksum_text)
    if not match or match[2] != name:
        raise ReleaseError(f"The checksum must name {name}")
    if hashlib.sha256(image).hexdigest() != match[1]:
        raise ReleaseError(f"The checksum for {name} does not match")
    return match[1]


def verify_disk_image(path, version, build_number, architecture):
    verifier = Path(__file__).resolve().with_name("verify-dmg.sh")
    try:
        subprocess.run([str(verifier), str(path.resolve()), version, build_number, architecture], check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ReleaseError(f"Disk image verification failed for {path.name}") from error


class ReleasePublisher:
    def __init__(self, context, github, image_verifier=verify_disk_image, *, base_tag=""):
        if base_tag:
            if not base_tag.startswith("v") or version_key(base_tag[1:]) >= version_key(context.version):
                raise ReleaseError("The planned base tag must be an older stable release")
        self.context = context
        self.github = github
        self.image_verifier = image_verifier
        self.base_tag = base_tag
        self.endpoint = github.prefix
        self.release_id = None

    def _asset_map(self, release):
        assets = release.get("assets", [])
        names = [asset["name"] for asset in assets]
        if len(set(names)) != len(names) or not set(names).issubset(self.context.asset_names):
            raise ReleaseError("The release contains unexpected or duplicate assets")
        return {asset["name"]: asset for asset in assets}

    def _tag_commit(self, tag=None):
        return tag_commit(self.github, tag or self.context.tag)

    def _release_by_id(self, release_id):
        for delay in RETRY_DELAYS:
            if delay:
                time.sleep(delay)
            result = self.github.api("GET", f"{self.endpoint}/releases/{release_id}", allow_missing=True)
            if result is not None:
                return result
        raise ReleaseError("The known release could not be read after retrying")

    def _load_release(self, *, allow_matching_publication=False):
        context = self.context
        if self.release_id is not None:
            release = self._release_by_id(self.release_id)
        else:
            release = self.github.api("GET", f"{self.endpoint}/releases/tags/{context.tag}", allow_missing=True)
        if release is None:
            # The tag endpoint only finds published releases. Find pending drafts
            # through the release list, then fetch their current state by ID.
            matches = [item for item in self.github.releases() if item.get("tag_name") == context.tag]
            if len(matches) > 1:
                raise ReleaseError("Multiple releases use the requested version tag")
            if matches:
                release = self._release_by_id(matches[0]["id"])
            else:
                # GitHub's CLI also uses GraphQL to find drafts whose tag has
                # not been created yet. REST list results can lag behind writes.
                owner, name = context.repository.split("/")
                result = self.github.api("POST", "graphql", {
                    "query": "query($owner: String!, $name: String!, $tag: String!) { repository(owner: $owner, name: $name) { release(tagName: $tag) { databaseId } } }",
                    "variables": {"owner": owner, "name": name, "tag": context.tag},
                })
                repository = result.get("data", {}).get("repository")
                if repository is None:
                    raise ReleaseError("Could not inspect repository release metadata")
                candidate = repository.get("release")
                if candidate is not None:
                    release = self._release_by_id(candidate["databaseId"])
        commit = self._tag_commit()
        if release is None:
            if commit is not None:
                if commit != context.commit:
                    raise ReleaseError("The version tag targets a different commit")
                raise ReleaseError("The version tag already exists without an owned release")
            return None
        self._validate_release(release, commit, allow_matching_publication=allow_matching_publication)
        return release

    def _release_marker(self, release):
        markers = re.findall(r"^<!-- lumaluma-release (.+) -->$", release.get("body") or "", re.MULTILINE)
        if len(markers) != 1:
            return None
        try:
            marker = json.loads(markers[0])
        except json.JSONDecodeError:
            return None
        return marker if isinstance(marker, dict) else None

    def _validate_release(self, release, commit, *, allow_matching_publication=False, allow_missing_tag=False):
        context = self.context
        if release.get("tag_name") != context.tag or release.get("prerelease"):
            raise ReleaseError("The version is owned by a different release or workflow run")
        marker = self._release_marker(release)
        if marker != context.marker:
            if allow_matching_publication and not release["draft"] and commit == context.commit:
                return
            owner = marker.get("run_id") if marker else None
            if isinstance(owner, str) and re.fullmatch(r"[1-9][0-9]*", owner) and owner != context.run_id:
                run = f"https://github.com/{context.repository}/actions/runs/{owner}"
                raise ReleaseError(f"{context.tag} is owned by another workflow run: {run}")
            raise ReleaseError(f"{context.tag} is owned by a different release or workflow run")
        if release.get("target_commitish") != context.commit:
            raise ReleaseError("The release targets a different commit")
        if commit is not None and commit != context.commit:
            raise ReleaseError("The version tag targets a different commit")
        if not release["draft"] and commit is None and not allow_missing_tag:
            raise ReleaseError("The published release tag is missing")
        self._asset_map(release)
        self.release_id = release["id"]

    def _publication_candidate(self):
        release = self._load_release(allow_matching_publication=True)
        if release is not None and not release["draft"]:
            return release
        releases = stable_releases(self.github)
        existing = published_release_for_commit(self.github, releases, self.context.commit)
        if existing is not None:
            return existing
        require_newer_candidate(self.github, releases, self.context.commit, self.context.version)
        return release

    def _wait_for_publication(self):
        for delay in RETRY_DELAYS:
            if delay:
                time.sleep(delay)
            release = self.github.api("GET", f"{self.endpoint}/releases/{self.release_id}", allow_missing=True)
            if release is not None:
                commit = self._tag_commit()
                self._validate_release(release, commit, allow_missing_tag=True)
                if not release["draft"] and commit is not None:
                    return release
        raise ReleaseError("GitHub did not confirm publication after retrying. Re-run the same workflow run.")

    def _verify_checksums(self, contents):
        return {
            name: verify_checksum(name, contents[name], contents[f"{name}.sha256"])
            for name in self.context.disk_images.values()
        }

    def _verify_images(self, paths):
        for architecture, name in self.context.disk_images.items():
            self.image_verifier(paths[name], self.context.version, self.context.run_number, architecture)

    def _verify_remote(self, release, expected=None):
        assets = self._asset_map(release)
        missing = set(self.context.asset_names) - assets.keys()
        if missing:
            raise ReleaseError(f"The release is missing {', '.join(sorted(missing))}")
        downloaded = {}
        for name, asset in assets.items():
            if asset.get("state") != "uploaded" or asset.get("size", 0) <= 0:
                raise ReleaseError(f"{name} has not finished uploading")
            contents = self.github.download(asset["id"])
            if len(contents) != asset["size"]:
                raise ReleaseError(f"{name} has an unexpected size")
            if expected is None:
                downloaded[name] = contents
            elif contents != expected[name]:
                raise ReleaseError(f"The uploaded {name} differs from the local artifact")
        if expected is not None:
            # The uploaded bytes matched the images and checksums already verified locally.
            return
        digests = self._verify_checksums(downloaded)
        try:
            with tempfile.TemporaryDirectory(prefix="lumaluma-release-") as directory:
                paths = {name: Path(directory) / name for name in self.context.disk_images.values()}
                for name, path in paths.items():
                    path.write_bytes(downloaded[name])
                self._verify_images(paths)
        except OSError as error:
            raise ReleaseError("Could not stage the downloaded disk images for verification") from error
        return digests

    def _report_publication(self, release):
        owned = release["tag_name"] == self.context.tag and self._release_marker(release) == self.context.marker
        digests = self._verify_remote(release) if owned else None
        return self._outputs(True, digests, tag=release["tag_name"])

    def preflight(self):
        release = self._publication_candidate()
        if release is not None and not release["draft"]:
            self._report_publication(release)
            return True
        self._outputs(False)
        return False

    def _changes(self):
        if not self.base_tag:
            return ""
        context = self.context
        base_commit = published_tag_commit(self.github, self.base_tag)
        comparison = compare_commits(self.github, base_commit, context.commit)
        if comparison.get("status") != "ahead":
            raise ReleaseError(f"Commit {context.commit} must descend from planned base {self.base_tag}")
        subjects = []
        for entry in comparison.get("commits", [])[:20]:
            message = entry["commit"]["message"].strip().splitlines()
            if message:
                subjects.append(f"- {html.escape(message[0])}\n")
        link = f"https://github.com/{context.repository}/compare/{self.base_tag}...{context.commit}"
        changes = "".join(subjects) + "\n" if subjects else ""
        return f"### Changes\n\n{changes}[Compare changes since {self.base_tag}]({link})\n\n"

    def _notes(self):
        context = self.context
        marker = json.dumps(context.marker, sort_keys=True, separators=(",", ":"))
        return (
            f"## Luma Luma {context.version}\n\n"
            "Make your compatible MacBook display brighter, even when macOS brightness "
            "is already at 100%. Luma Luma uses available HDR headroom and supports "
            "the MacBook brightness keys.\n\n"
            "For macOS 14 or newer, download the `arm64` disk image for Apple silicon "
            "or the `x86_64` disk image for Intel.\n\n"
            "Open the disk image, drag **Luma Luma.app** into **Applications**, and open the app. "
            "This build uses ad-hoc signing. macOS may require approval in "
            "**System Settings → Privacy & Security** on first launch. "
            "Enable Accessibility access in the app's shortcut settings to use the brightness keys.\n\n"
            f"[User guide](https://github.com/{context.repository}/blob/{context.commit}/docs/USAGE.md) "
            f"· [Source commit](https://github.com/{context.repository}/commit/{context.commit}) "
            f"· [Build run](https://github.com/{context.repository}/actions/runs/{context.run_id})\n\n"
            "Use the corresponding `.dmg.sha256` file to verify the disk image download.\n\n"
            f"{self._changes()}"
            f"<!-- lumaluma-release {marker} -->\n"
        )

    def _asset_snapshot(self, release):
        return {
            name: (asset["id"], asset.get("state"), asset.get("size"), asset.get("digest"))
            for name, asset in self._asset_map(release).items()
        }

    def publish(self, assets_dir):
        release = self._publication_candidate()
        if release is not None and not release["draft"]:
            return self._report_publication(release)

        paths = {name: Path(assets_dir) / name for name in self.context.asset_names}
        contents = {}
        for name, path in paths.items():
            try:
                contents[name] = path.read_bytes()
            except OSError as error:
                raise ReleaseError(f"Could not read the local release asset {name}") from error
        digests = self._verify_checksums(contents)
        self._verify_images(paths)
        release = self._publication_candidate()
        if release is not None and not release["draft"]:
            return self._report_publication(release)
        if release is None:
            release = self.github.api("POST", f"{self.endpoint}/releases", {
                "tag_name": self.context.tag, "target_commitish": self.context.commit,
                "name": f"Luma Luma {self.context.version}", "body": self._notes(),
                "draft": True, "prerelease": False,
            })
            self.release_id = release["id"]
        for name, path in paths.items():
            release = self._load_release()
            if release is None or not release["draft"]:
                raise ReleaseError("The draft changed while uploading release assets")
            asset = self._asset_map(release).get(name)
            if asset is not None:
                if asset.get("state") == "uploaded" and self.github.download(asset["id"]) == contents[name]:
                    continue
                self.github.api("DELETE", f"{self.endpoint}/releases/assets/{asset['id']}")
            release = self._load_release()
            if release is None or not release["draft"]:
                raise ReleaseError("The draft changed before uploading a release asset")
            self.github.upload(release["id"], path)
        release = self._load_release()
        if release is None or not release["draft"]:
            raise ReleaseError("The draft changed before publication")
        self._verify_remote(release, contents)
        verified_assets = self._asset_snapshot(release)
        candidate = self._publication_candidate()
        if candidate is not None and not candidate["draft"]:
            return self._report_publication(candidate)
        release = self._load_release()
        if release is None or not release["draft"] or self._asset_snapshot(release) != verified_assets:
            raise ReleaseError("The verified draft assets changed before publication")
        self.github.api("PATCH", f"{self.endpoint}/releases/{release['id']}", {
            "draft": False, "make_latest": "true",
        })
        published = self._wait_for_publication()
        self._verify_remote(published, contents)
        return self._outputs(True, digests)

    def _outputs(self, published, digests=None, *, tag=None):
        context = self.context
        tag = tag or context.tag
        version = tag[1:]
        url = f"https://github.com/{context.repository}/releases/tag/{tag}" if published else ""
        values = {
            "version": version, "build_number": context.run_number,
            "published": str(published).lower(), "release_url": url,
        }
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with open(output, "a", encoding="utf-8") as file:
                file.writelines(f"{key}={value}\n" for key, value in values.items())
        if published:
            print(url)
            summary = os.environ.get("GITHUB_STEP_SUMMARY")
            if summary:
                with open(summary, "a", encoding="utf-8") as file:
                    file.write(f"## Luma Luma {version}\n\n[Download release]({url})\n\n")
                    file.write(f"Commit `{context.commit}`\n\n")
                    if digests:
                        for name, digest in digests.items():
                            file.write(f"- `{name}` · SHA-256 `{digest}`\n")
        else:
            print(f"Preparing Luma Luma {context.version}")
        return url


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "publish"))
    parser.add_argument("--assets-dir", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        context = ReleaseContext.from_environment()
        publisher = ReleasePublisher(context, GitHub(context.repository), base_tag=os.environ.get("RELEASE_BASE_TAG", ""))
        if args.command == "preflight":
            publisher.preflight()
        else:
            publisher.publish(args.assets_dir)
    except ReleaseError as error:
        print(f"Release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
