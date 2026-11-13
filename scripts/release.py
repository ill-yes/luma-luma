#!/usr/bin/env python3
"""Create resumable GitHub releases for manually dispatched Luma Luma builds."""

import argparse
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import sys
import time
import zipfile


class ReleaseError(Exception):
    """A release cannot be completed safely."""


def version_for_run(run_number):
    if not re.fullmatch(r"[1-9][0-9]*", str(run_number)):
        raise ReleaseError("The workflow run number must be a positive integer")
    return f"0.1.{run_number}"


@dataclass(frozen=True)
class ReleaseContext:
    repository: str
    commit: str
    run_id: str
    run_number: str

    def __post_init__(self):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", self.repository):
            raise ReleaseError("Invalid GitHub repository")
        if not re.fullmatch(r"[0-9a-f]{40}", self.commit):
            raise ReleaseError("The release commit must be a full Git SHA")
        if not re.fullmatch(r"[1-9][0-9]*", self.run_id):
            raise ReleaseError("Invalid GitHub workflow run ID")
        version_for_run(self.run_number)

    @classmethod
    def from_environment(cls):
        names = ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_NUMBER")
        try:
            return cls(*(os.environ[name] for name in names))
        except KeyError as error:
            raise ReleaseError(f"Missing environment variable {error.args[0]}") from error

    @property
    def version(self):
        return version_for_run(self.run_number)

    @property
    def tag(self):
        return f"v{self.version}"

    @property
    def archive_name(self):
        return f"LumaLuma-{self.version}-macos-universal.zip"

    @property
    def asset_names(self):
        return (self.archive_name, f"{self.archive_name}.sha256")

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

    def _run(self, args, payload=None, allow_missing=False, binary=False):
        result = subprocess.run(
            ["gh", *args], input=payload, capture_output=True,
            text=not binary, check=False,
        )
        if result.returncode:
            error_text = result.stderr.decode(errors="replace") if binary else result.stderr
            if allow_missing and re.search(r"\bHTTP 404\b", error_text):
                return None
            # gh may include remote response content in stderr. Keep errors free of tokens.
            raise ReleaseError(f"GitHub request failed (gh exit {result.returncode})")
        return result.stdout

    def api(self, method, path, payload=None, allow_missing=False):
        args = ["api", path, "--method", method]
        encoded = None
        if payload is not None:
            args.extend(["--input", "-"])
            encoded = json.dumps(payload)
        output = self._run(args, encoded, allow_missing)
        if output is None:
            return None
        return json.loads(output) if output.strip() else None

    def releases(self):
        output = self._run(["api", f"{self.prefix}/releases?per_page=100", "--paginate", "--slurp"])
        return [release for page in json.loads(output) for release in page]

    def download(self, asset_id):
        return self._run([
            "api", f"{self.prefix}/releases/assets/{asset_id}",
            "--header", "Accept: application/octet-stream",
        ], binary=True)

    def upload(self, release_id, path):
        from urllib.parse import quote
        endpoint = (
            f"https://uploads.github.com/{self.prefix}/releases/{release_id}/assets"
            f"?name={quote(path.name, safe='')}"
        )
        output = self._run([
            "api", endpoint, "--method", "POST", "--header",
            "Content-Type: application/octet-stream", "--input", str(path),
        ])
        return json.loads(output)


def verify_archive(context, archive, checksum):
    try:
        checksum_text = checksum.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise ReleaseError("The checksum file must contain ASCII text") from error
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", checksum_text)
    if not match or match[2] != context.archive_name:
        raise ReleaseError("The checksum must name the expected release archive")
    if hashlib.sha256(archive).hexdigest() != match[1]:
        raise ReleaseError("The release archive checksum does not match")
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            for name in bundle.namelist():
                path = PurePosixPath(name)
                if path.is_absolute() or ".." in path.parts:
                    raise ReleaseError("The release ZIP contains an unsafe path")
            plist_name = "Luma Luma.app/Contents/Info.plist"
            if bundle.getinfo(plist_name).file_size > 1024 * 1024:
                raise ReleaseError("The app property list is unexpectedly large")
            info = plistlib.loads(bundle.read(plist_name))
            if not isinstance(info, dict):
                raise ReleaseError("The app property list must contain a dictionary")
            expected = {
                "CFBundleIdentifier": "dev.illyes.lumaluma",
                "CFBundleShortVersionString": context.version,
                "CFBundleVersion": context.run_number,
            }
            if any(info.get(key) != value for key, value in expected.items()):
                raise ReleaseError("The app version or bundle identity does not match this release")
            for path in (
                "Contents/MacOS/LumaLuma", "Contents/Helpers/LumaLumaGammaHelper",
                "Contents/Resources/LICENSE", "Contents/Resources/LumaLuma.icns",
            ):
                bundle.getinfo(f"Luma Luma.app/{path}")
            if bundle.testzip() is not None:
                raise ReleaseError("The release ZIP contains a corrupt entry")
    except (zipfile.BadZipFile, KeyError, plistlib.InvalidFileException, ValueError) as error:
        raise ReleaseError("The release ZIP or app property list is invalid") from error
    return match[1]


class ReleasePublisher:
    def __init__(self, context, github):
        self.context = context
        self.github = github
        self.endpoint = github.prefix
        self.release_id = None

    def _asset_map(self, release):
        assets = release.get("assets", [])
        names = [asset["name"] for asset in assets]
        if len(set(names)) != len(names) or not set(names).issubset(self.context.asset_names):
            raise ReleaseError("The release contains unexpected or duplicate assets")
        return {asset["name"]: asset for asset in assets}

    def _tag_commit(self):
        reference = self.github.api(
            "GET", f"{self.endpoint}/git/ref/tags/{self.context.tag}", allow_missing=True,
        )
        if reference is None:
            return None
        target = reference.get("object", {})
        visited = set()
        while target.get("type") == "tag":
            sha = target.get("sha")
            if sha in visited:
                raise ReleaseError("The version tag contains an invalid reference cycle")
            visited.add(sha)
            tag = self.github.api("GET", f"{self.endpoint}/git/tags/{sha}")
            target = tag.get("object", {})
        if target.get("type") != "commit":
            raise ReleaseError("The version tag does not reference a commit")
        return target.get("sha")

    def _release_by_id(self, release_id):
        for delay in (0, 1, 2, 4):
            if delay:
                time.sleep(delay)
            result = self.github.api("GET", f"{self.endpoint}/releases/{release_id}", allow_missing=True)
            if result is not None:
                return result
        raise ReleaseError("The known release could not be read after retrying")

    def _load_release(self, allow_hidden_release=False):
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
        tag_commit = self._tag_commit()
        if release is None:
            if tag_commit is not None:
                if tag_commit != context.commit:
                    raise ReleaseError("The version tag targets a different commit")
                # Read-only tokens may not see an unpublished draft. The publisher
                # resolves ownership with its write token before changing anything.
                if allow_hidden_release:
                    return None
                raise ReleaseError("The version tag already exists without an owned release")
            return None
        markers = re.findall(r"^<!-- lumaluma-release (.+) -->$", release.get("body") or "", re.MULTILINE)
        try:
            owned = len(markers) == 1 and json.loads(markers[0]) == context.marker
        except json.JSONDecodeError:
            owned = False
        if not owned or release.get("tag_name") != context.tag or release.get("prerelease"):
            raise ReleaseError("The version is owned by a different release or workflow run")
        if release.get("target_commitish") != context.commit:
            raise ReleaseError("The release targets a different commit")
        if tag_commit is not None and tag_commit != context.commit:
            raise ReleaseError("The version tag targets a different commit")
        if not release.get("draft") and tag_commit is None:
            raise ReleaseError("The published release tag is missing")
        self._asset_map(release)
        self.release_id = release["id"]
        return release

    def _verify_remote(self, release, expected=None):
        assets = self._asset_map(release)
        if set(assets) != set(self.context.asset_names):
            raise ReleaseError("The release is missing an archive or checksum asset")
        downloaded = {}
        for name, asset in assets.items():
            if asset.get("state") != "uploaded" or asset.get("size", 0) <= 0:
                raise ReleaseError("A release asset has not finished uploading")
            contents = self.github.download(asset["id"])
            if len(contents) != asset["size"]:
                raise ReleaseError("A release asset has an unexpected size")
            if expected is not None and contents != expected[name]:
                raise ReleaseError("The uploaded release asset differs from the local artifact")
            downloaded[name] = contents
        return verify_archive(self.context, *(downloaded[name] for name in self.context.asset_names))

    def prepare(self):
        release = self._load_release(allow_hidden_release=True)
        published = release is not None and not release["draft"]
        if published:
            self._verify_remote(release)
        self._outputs(published)
        return published

    def _notes(self):
        context = self.context
        marker = json.dumps(context.marker, sort_keys=True, separators=(",", ":"))
        return (
            f"## Luma Luma {context.version}\n\n"
            "Download the universal ZIP for macOS 14 or newer. It contains the app and "
            "display helper for Apple silicon and Intel Macs.\n\n"
            "Extract the ZIP, move **Luma Luma.app** to **Applications**, and open it. "
            "This build uses ad-hoc signing. macOS may require approval in "
            "**System Settings → Privacy & Security** on first launch. "
            "Enable Accessibility access in the app's shortcut settings to use the brightness keys.\n\n"
            f"[User guide](https://github.com/{context.repository}/blob/{context.commit}/docs/USAGE.md) "
            f"· [Source commit](https://github.com/{context.repository}/commit/{context.commit}) "
            f"· [Build run](https://github.com/{context.repository}/actions/runs/{context.run_id})\n\n"
            "The accompanying `.sha256` file verifies the ZIP download.\n\n"
            f"<!-- lumaluma-release {marker} -->\n"
        )

    def _make_latest(self):
        current = tuple(map(int, self.context.version.split(".")))
        for release in self.github.releases():
            match = re.fullmatch(r"v([0-9]+)\.([0-9]+)\.([0-9]+)", release.get("tag_name", ""))
            if match and not release.get("draft") and not release.get("prerelease"):
                if tuple(map(int, match.groups())) > current:
                    return "false"
        return "true"

    def publish(self, assets_dir):
        release = self._load_release()
        if release is not None and not release["draft"]:
            digest = self._verify_remote(release)
            self._outputs(True, digest)
            return self.context.url

        paths = {name: Path(assets_dir) / name for name in self.context.asset_names}
        try:
            contents = {name: path.read_bytes() for name, path in paths.items()}
        except OSError as error:
            raise ReleaseError("The local release archive or checksum is missing") from error
        digest = verify_archive(self.context, *(contents[name] for name in self.context.asset_names))
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
        self.github.api("PATCH", f"{self.endpoint}/releases/{release['id']}", {
            "draft": False, "make_latest": self._make_latest(),
        })
        published = self._load_release()
        if published is None or published["draft"]:
            raise ReleaseError("GitHub did not publish the release")
        self._verify_remote(published, contents)
        self._outputs(True, digest)
        return self.context.url

    def _outputs(self, published, digest=None):
        context = self.context
        values = {
            "version": context.version, "build_number": context.run_number,
            "published": str(published).lower(), "release_url": context.url if published else "",
        }
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with open(output, "a", encoding="utf-8") as file:
                file.writelines(f"{key}={value}\n" for key, value in values.items())
        if published:
            print(context.url)
            summary = os.environ.get("GITHUB_STEP_SUMMARY")
            if summary:
                with open(summary, "a", encoding="utf-8") as file:
                    file.write(f"## Luma Luma {context.version}\n\n[Download release]({context.url})\n\n")
                    file.write(f"Commit `{context.commit}`\n\n")
                    if digest:
                        file.write(f"SHA-256 `{digest}`\n")
        else:
            print(f"Preparing Luma Luma {context.version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "publish"))
    parser.add_argument("--assets-dir", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        context = ReleaseContext.from_environment()
        publisher = ReleasePublisher(context, GitHub(context.repository))
        if args.command == "prepare":
            publisher.prepare()
        else:
            publisher.publish(args.assets_dir)
    except ReleaseError as error:
        print(f"Release error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
