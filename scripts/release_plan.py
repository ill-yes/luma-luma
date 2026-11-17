#!/usr/bin/env python3
"""Resolve the immutable version plan for one manually dispatched release run."""

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Optional

from release_metadata import (
    ReleaseError, published_release_for_commit, require_newer_candidate, stable_releases, tag_commit, version_key,
)


PLAN_NAME = "release-plan.json"
PLAN_LIMIT = 4_096
BUMPS = ("patch", "minor", "major")


def _validate_binding(commit, run_id, build_number, bump):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ReleaseError("The release commit must be a full Git SHA")
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[1-9][0-9]*", build_number):
        raise ReleaseError("The workflow run ID and build number must be positive integers")
    if bump not in BUMPS:
        raise ReleaseError("The release bump must be patch, minor or major")


@dataclass(frozen=True)
class Dispatch:
    repository: str
    run_id: str
    commit: str
    bump: str
    build_number: str
    attempt: int

    def __post_init__(self):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", self.repository):
            raise ReleaseError("Invalid GitHub repository")
        _validate_binding(self.commit, self.run_id, self.build_number, self.bump)
        if self.attempt < 1:
            raise ReleaseError("The workflow run attempt must be a positive integer")

    @classmethod
    def from_environment(cls):
        if os.environ.get("GITHUB_REF") != "refs/heads/main":
            raise ReleaseError("Dispatch releases from the main branch")
        try:
            attempt = os.environ["GITHUB_RUN_ATTEMPT"]
            if not re.fullmatch(r"[1-9][0-9]*", attempt):
                raise ReleaseError("The workflow run attempt must be a positive integer")
            return cls(
                repository=os.environ["GITHUB_REPOSITORY"], run_id=os.environ["GITHUB_RUN_ID"],
                commit=os.environ["GITHUB_SHA"], bump=os.environ["RELEASE_BUMP"],
                build_number=os.environ["GITHUB_RUN_NUMBER"], attempt=int(attempt),
            )
        except KeyError as error:
            raise ReleaseError(f"Missing environment variable {error.args[0]}") from error


def bumped_version(base_tag, bump):
    if base_tag and not base_tag.startswith("v"):
        raise ReleaseError("Invalid release plan base tag")
    major, minor, patch = version_key(base_tag[1:]) if base_tag else (0, 0, 0)
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    if bump == "major":
        return f"{major + 1}.0.0"
    raise ReleaseError("The release bump must be patch, minor or major")


@dataclass(frozen=True)
class ReleasePlan:
    run_id: str
    commit: str
    bump: str
    version: str
    base_tag: str
    build_number: str

    def __post_init__(self):
        _validate_binding(self.commit, self.run_id, self.build_number, self.bump)
        if self.version != bumped_version(self.base_tag, self.bump):
            raise ReleaseError("The frozen release version does not match its base tag and bump")

    @property
    def tag(self):
        return f"v{self.version}"

    def to_bytes(self):
        return (json.dumps(asdict(self), sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")

    @classmethod
    def from_bytes(cls, contents):
        def unique_fields(pairs):
            fields = dict(pairs)
            if len(fields) != len(pairs):
                raise ReleaseError("The frozen release plan contains duplicate fields")
            return fields

        try:
            values = json.loads(contents.decode("utf-8"), object_pairs_hook=unique_fields)
        except (UnicodeDecodeError, ValueError, RecursionError) as error:
            raise ReleaseError("The frozen release plan must be valid UTF-8 JSON") from error
        if (not isinstance(values, dict) or set(values) != set(cls.__annotations__)
                or not all(isinstance(value, str) for value in values.values())):
            raise ReleaseError("The frozen release plan has invalid fields")
        return cls(**values)

    def validate_dispatch(self, dispatch):
        if (self.run_id, self.commit, self.bump, self.build_number) != (
            dispatch.run_id, dispatch.commit, dispatch.bump, dispatch.build_number
        ):
            raise ReleaseError("The frozen release plan does not match this workflow run, commit, bump or build number")


@dataclass(frozen=True)
class ResolvedRelease:
    mode: str
    version: str
    base_tag: str = ""
    release_url: str = ""
    plan_to_upload: Optional[ReleasePlan] = None


def _restore_plan(github, dispatch):
    endpoint = f"{github.prefix}/actions/runs/{dispatch.run_id}/artifacts?name={PLAN_NAME}&per_page=100"
    response = github.api("GET", endpoint)
    artifacts = response.get("artifacts") if isinstance(response, dict) else None
    if (not isinstance(artifacts, list) or type(response.get("total_count")) is not int
            or response["total_count"] != len(artifacts)):
        raise ReleaseError("Could not inspect the workflow's frozen release plan artifacts")
    if any(not isinstance(artifact, dict) or artifact.get("name") != PLAN_NAME
           or type(artifact.get("expired")) is not bool for artifact in artifacts):
        raise ReleaseError("GitHub returned invalid frozen release plan metadata")
    retained = [artifact for artifact in artifacts if not artifact["expired"]]
    if not retained:
        raise ReleaseError("This run has no retained release plan. Start a new release dispatch.")
    if len(retained) != 1:
        raise ReleaseError("The workflow run has multiple frozen release plans")
    artifact = retained[0]
    artifact_id, size, digest = (artifact.get(key) for key in ("id", "size_in_bytes", "digest"))
    run = artifact.get("workflow_run")
    if (type(artifact_id) is not int or artifact_id <= 0 or type(size) is not int or not 0 < size <= PLAN_LIMIT
            or not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
            or not isinstance(run, dict) or str(run.get("id")) != dispatch.run_id
            or run.get("head_sha") != dispatch.commit):
        raise ReleaseError("GitHub returned invalid metadata for this run's frozen release plan")
    contents = github.download_artifact(artifact_id)
    if len(contents) != size or "sha256:" + hashlib.sha256(contents).hexdigest() != digest:
        raise ReleaseError("The downloaded release plan does not match its GitHub artifact size or digest")
    plan = ReleasePlan.from_bytes(contents)
    plan.validate_dispatch(dispatch)
    return plan


def _owned_published_release(github, releases, dispatch):
    owned = None
    for release in releases:
        body = release.get("body") or ""
        if not isinstance(body, str):
            raise ReleaseError(f"Published release {release['tag_name']} has invalid release notes")
        markers = re.findall(r"^<!-- lumaluma-release (.+) -->$", body, re.MULTILINE)
        for text in markers:
            try:
                marker = json.loads(text)
            except json.JSONDecodeError:
                continue
            if not isinstance(marker, dict) or marker.get("run_id") != dispatch.run_id:
                continue
            tag = release["tag_name"]
            if owned is not None or len(markers) != 1 or marker != {
                "run_id": dispatch.run_id, "commit": dispatch.commit, "version": tag[1:],
            }:
                raise ReleaseError("Conflicting published release ownership for this workflow run")
            if tag_commit(github, tag) != dispatch.commit:
                raise ReleaseError("This run's published release tag does not target its original commit")
            owned = release
    return owned


def _existing_release(mode, release, dispatch):
    tag = release["tag_name"]
    return ResolvedRelease(mode, tag[1:], release_url=f"https://github.com/{dispatch.repository}/releases/tag/{tag}")


def resolve_release(github, dispatch):
    releases = stable_releases(github)
    owned = _owned_published_release(github, releases, dispatch)
    if owned is not None:
        return _existing_release("verify", owned, dispatch)

    fresh = dispatch.attempt == 1
    if fresh:
        duplicate = published_release_for_commit(github, releases, dispatch.commit)
        if duplicate is not None:
            return _existing_release("duplicate", duplicate, dispatch)
        base_tag = releases[0]["tag_name"] if releases else ""
        plan = ReleasePlan(
            dispatch.run_id, dispatch.commit, dispatch.bump, bumped_version(base_tag, dispatch.bump),
            base_tag, dispatch.build_number,
        )
    else:
        plan = _restore_plan(github, dispatch)

    require_newer_candidate(github, releases, dispatch.commit, plan.version)
    candidate_commit = tag_commit(github, plan.tag)
    if candidate_commit is not None and (fresh or candidate_commit != dispatch.commit):
        raise ReleaseError(f"Release tag {plan.tag} already exists. Choose a different version bump.")
    # A retry can see its reserved tag before the read-only token can see the draft.
    # The publisher checks that the existing release is owned by this run.
    return ResolvedRelease("build", plan.version, plan.base_tag, plan_to_upload=plan if fresh else None)


def _report(resolved):
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as file:
            file.write(f"mode={resolved.mode}\nversion={resolved.version}\nbase_tag={resolved.base_tag}\n")
            file.write(f"upload_plan={str(resolved.plan_to_upload is not None).lower()}\n")
            file.write(f"release_url={resolved.release_url}\n")
    if resolved.mode == "build":
        print(f"Preparing Luma Luma {resolved.version}")
    elif resolved.mode == "verify":
        print(f"Verifying this run's published release {resolved.version}")
    else:
        print(f"This commit is already available as Luma Luma {resolved.version} ({resolved.release_url})")
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as file:
                file.write(f"This commit is already available as [Luma Luma {resolved.version}]({resolved.release_url}).\n")


def main(argv=None):
    from release import GitHub

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-file", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        dispatch = Dispatch.from_environment()
        resolved = resolve_release(GitHub(dispatch.repository), dispatch)
        if resolved.plan_to_upload is not None:
            args.plan_file.write_bytes(resolved.plan_to_upload.to_bytes())
        _report(resolved)
    except (ReleaseError, OSError, ValueError) as error:
        print(f"Release plan error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
