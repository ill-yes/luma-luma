"""Stable version history shared by the release planner and publisher."""

import re


class ReleaseError(Exception):
    """A release cannot be completed safely."""


VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def version_key(version):
    match = re.fullmatch(VERSION_PATTERN, version) if isinstance(version, str) else None
    if not match:
        raise ReleaseError("The release version must use the X.Y.Z format")
    return tuple(map(int, match.groups()))


def stable_releases(github):
    releases = [
        release for release in github.releases()
        if not release.get("draft") and not release.get("prerelease")
        and re.fullmatch(f"v{VERSION_PATTERN}", release.get("tag_name") or "")
    ]
    return sorted(releases, key=lambda release: version_key(release["tag_name"][1:]), reverse=True)


def tag_commit(github, tag):
    reference = github.api("GET", f"{github.prefix}/git/ref/tags/{tag}", allow_missing=True)
    if reference is None:
        return None
    target = reference.get("object", {})
    visited = set()
    while target.get("type") == "tag":
        sha = target.get("sha", "")
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ReleaseError(f"{tag} contains an invalid tag reference")
        if sha in visited:
            raise ReleaseError(f"{tag} contains an invalid reference cycle")
        visited.add(sha)
        annotated = github.api("GET", f"{github.prefix}/git/tags/{sha}")
        target = annotated.get("object", {})
    sha = target.get("sha", "")
    if target.get("type") != "commit" or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ReleaseError(f"{tag} does not reference a commit")
    return sha


def published_tag_commit(github, tag):
    commit = tag_commit(github, tag)
    if commit is None:
        raise ReleaseError(f"Published release {tag} has no Git tag")
    return commit


def published_release_for_commit(github, releases, commit):
    for release in releases:
        if published_tag_commit(github, release["tag_name"]) == commit:
            return release
    return None


def compare_commits(github, base_sha, commit):
    return github.api("GET", f"{github.prefix}/compare/{base_sha}...{commit}")


def require_newer_candidate(github, releases, commit, version):
    candidate_version = version_key(version)
    if not releases:
        return
    latest = releases[0]["tag_name"]
    if candidate_version <= version_key(latest[1:]):
        raise ReleaseError(f"Planned v{version} is no longer newer than {latest}. Start a new release run.")
    base = published_tag_commit(github, latest)
    if compare_commits(github, base, commit).get("status") != "ahead":
        raise ReleaseError(f"Commit {commit} must descend from published release {latest}")
