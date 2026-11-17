import contextlib
from dataclasses import replace
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import release_plan


REPOSITORY = "ill-yes/luma-luma"
COMMIT = "a" * 40
PREVIOUS_COMMIT = "b" * 40
RUN_ID = "123"
BUILD_NUMBER = "17"
ENVIRONMENT = {
    "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_SHA": COMMIT,
    "GITHUB_RUN_ID": RUN_ID, "GITHUB_RUN_NUMBER": BUILD_NUMBER, "GITHUB_RUN_ATTEMPT": "1", "RELEASE_BUMP": "patch",
}


class FakeGitHub:
    def __init__(self):
        self.prefix = f"repos/{REPOSITORY}"
        self.entries = []
        self.tags = {}
        self.annotated_tags = {}
        self.compares = []
        self.comparison_status = "ahead"
        self.artifacts = []
        self.contents = b""
        self.downloads = []

    def add_release(self, tag, sha=PREVIOUS_COMMIT, **kwargs):
        self.tags[tag] = {"sha": sha, "type": "commit"}
        self.entries.append({"tag_name": tag, "draft": False, "prerelease": False, "target_commitish": "main", **kwargs})

    def retain(self, contents, **overrides):
        self.contents = contents
        self.artifacts.append({
            "id": 1234, "name": "release-plan.json", "expired": False, "size_in_bytes": len(contents),
            "digest": "sha256:" + hashlib.sha256(contents).hexdigest(),
            "workflow_run": {"id": int(RUN_ID), "head_sha": COMMIT}, **overrides,
        })

    def releases(self):
        return self.entries

    def api(self, method, url, allow_missing=False):
        if method != "GET":
            raise AssertionError(f"Planner attempted a write: {method}")
        ref_endpoint = f"{self.prefix}/git/ref/tags/"
        tag_endpoint = f"{self.prefix}/git/tags/"
        compare_endpoint = f"{self.prefix}/compare/"
        if url.startswith(ref_endpoint):
            target = self.tags.get(url.removeprefix(ref_endpoint))
            return {"object": target} if target else None
        if url.startswith(tag_endpoint):
            return {"object": self.annotated_tags[url.removeprefix(tag_endpoint)]}
        if url.startswith(compare_endpoint):
            self.compares.append(url.removeprefix(compare_endpoint))
            return {"status": self.comparison_status}
        if url == f"{self.prefix}/actions/runs/{RUN_ID}/artifacts?name=release-plan.json&per_page=100":
            return {"artifacts": self.artifacts, "total_count": len(self.artifacts)}
        raise AssertionError(f"Unexpected GitHub endpoint {url}")

    def download_artifact(self, artifact_id):
        self.downloads.append(artifact_id)
        return self.contents


class ReleasePlanTests(unittest.TestCase):
    def setUp(self):
        self.github = FakeGitHub()
        self.dispatch = release_plan.Dispatch(REPOSITORY, RUN_ID, COMMIT, "patch", BUILD_NUMBER, 1)

    def resolve(self, **dispatch_changes):
        return release_plan.resolve_release(self.github, replace(self.dispatch, **dispatch_changes))

    def frozen_plan(self, **changes):
        values = dict(run_id=RUN_ID, commit=COMMIT, bump="patch", version="1.10.4", base_tag="v1.10.3", build_number=BUILD_NUMBER)
        return release_plan.ReleasePlan(**(values | changes))

    def test_dispatch_is_bound_to_main_and_validated_environment(self):
        with patch.dict(os.environ, ENVIRONMENT, clear=True):
            self.assertEqual(release_plan.Dispatch.from_environment(), self.dispatch)
        for field, value in (
            ("GITHUB_REF", "refs/heads/feature"), ("GITHUB_SHA", "main"), ("GITHUB_RUN_ID", "0"),
            ("GITHUB_RUN_ATTEMPT", "02"), ("GITHUB_RUN_NUMBER", "-1"), ("RELEASE_BUMP", "Patch"),
        ):
            with self.subTest(field=field), patch.dict(os.environ, ENVIRONMENT | {field: value}, clear=True):
                with self.assertRaises(release_plan.ReleaseError):
                    release_plan.Dispatch.from_environment()

    def test_bumps_use_the_greatest_stable_numeric_tag(self):
        self.github.add_release("v1.9.99")
        self.github.add_release("v1.10.3")
        self.github.add_release("v99.0.0", COMMIT, draft=True)
        self.github.add_release("v100.0.0", COMMIT, prerelease=True)
        self.github.add_release("v2.0.0-preview", COMMIT)
        self.github.add_release("v02.0.0", COMMIT)
        for bump, version in (("patch", "1.10.4"), ("minor", "1.11.0"), ("major", "2.0.0")):
            with self.subTest(bump=bump):
                resolved = self.resolve(bump=bump)
                self.assertEqual((resolved.mode, resolved.version, resolved.base_tag), ("build", version, "v1.10.3"))
                self.assertEqual(resolved.plan_to_upload, self.frozen_plan(bump=bump, version=version))

    def test_no_existing_stable_release_bumps_from_zero(self):
        for bump, version in (("patch", "0.0.1"), ("minor", "0.1.0"), ("major", "1.0.0")):
            with self.subTest(bump=bump):
                resolved = self.resolve(bump=bump)
                self.assertEqual((resolved.version, resolved.base_tag), (version, ""))
        self.assertEqual(self.github.compares, [])

    def test_base_ancestry_uses_resolved_annotated_tag_instead_of_release_reference(self):
        self.github.add_release("v1.10.3", target_commitish="c" * 40)
        annotated_sha = "d" * 40
        self.github.tags["v1.10.3"] = {"sha": annotated_sha, "type": "tag"}
        self.github.annotated_tags[annotated_sha] = {"sha": PREVIOUS_COMMIT, "type": "commit"}
        self.github.comparison_status = "diverged"
        with self.assertRaisesRegex(release_plan.ReleaseError, "must descend from published release v1.10.3"):
            self.resolve()
        self.assertEqual(self.github.compares, [f"{PREVIOUS_COMMIT}...{COMMIT}"])

    def test_fresh_duplicate_uses_highest_published_release_of_actual_source(self):
        self.github.add_release("v2.0.0", target_commitish=COMMIT)
        self.github.add_release("v1.2.0", COMMIT)
        self.github.add_release("v1.10.0", COMMIT)
        self.github.add_release("v3.0.0", COMMIT, prerelease=True)
        resolved = self.resolve(bump="major")
        self.assertEqual((resolved.mode, resolved.version), ("duplicate", "1.10.0"))
        self.assertEqual(resolved.release_url, f"https://github.com/{REPOSITORY}/releases/tag/v1.10.0")
        self.assertIsNone(resolved.plan_to_upload)
        self.assertEqual(self.github.compares, [])

    def test_owned_published_version_is_verified_even_with_no_plan_and_newer_duplicate(self):
        marker = json.dumps({"run_id": RUN_ID, "commit": COMMIT, "version": "1.10.3"})
        self.github.add_release("v1.10.3", COMMIT, body=f"<!-- lumaluma-release {marker} -->\n")
        self.github.add_release("v2.0.0", COMMIT)
        resolved = self.resolve(attempt=2)
        self.assertEqual((resolved.mode, resolved.version), ("verify", "1.10.3"))
        self.assertIsNone(resolved.plan_to_upload)
        self.assertEqual(self.github.downloads, [])

    def test_published_owner_marker_cannot_contradict_tag_or_source(self):
        marker = json.dumps({"run_id": RUN_ID, "commit": COMMIT, "version": "1.10.3"})
        self.github.add_release("v1.10.3", PREVIOUS_COMMIT, body=f"<!-- lumaluma-release {marker} -->\n")
        with self.assertRaisesRegex(release_plan.ReleaseError, "does not target its original commit"):
            self.resolve(attempt=2)

    def test_retry_keeps_frozen_plan_and_checks_current_ancestry(self):
        other_commit = "c" * 40
        self.github.add_release("v1.10.3")
        self.github.add_release("v1.10.4", other_commit)
        frozen = self.frozen_plan(bump="minor", version="1.11.0")
        self.github.retain(frozen.to_bytes())
        resolved = self.resolve(bump="minor", attempt=2)
        self.assertEqual((resolved.mode, resolved.version, resolved.base_tag), ("build", "1.11.0", "v1.10.3"))
        self.assertIsNone(resolved.plan_to_upload)
        self.assertEqual(self.github.downloads, [1234])
        self.assertEqual(self.github.compares, [f"{other_commit}...{COMMIT}"])

    def test_retry_rejects_stale_frozen_plan(self):
        self.github.add_release("v1.10.4")
        self.github.retain(self.frozen_plan().to_bytes())
        with self.assertRaisesRegex(release_plan.ReleaseError, "no longer newer"):
            self.resolve(attempt=2)

    def test_retry_requires_a_nonexpired_plan_and_does_not_compute_duplicate(self):
        self.github.add_release("v1.10.3", COMMIT)
        with self.assertRaisesRegex(release_plan.ReleaseError, "no retained release plan"):
            self.resolve(attempt=2)
        self.github.retain(self.frozen_plan().to_bytes(), expired=True)
        with self.assertRaisesRegex(release_plan.ReleaseError, "no retained release plan"):
            self.resolve(attempt=3)

    def test_valid_frozen_plan_is_bound_to_original_dispatch(self):
        for plan in (
            self.frozen_plan(run_id="456"), self.frozen_plan(commit=PREVIOUS_COMMIT),
            self.frozen_plan(bump="major", version="2.0.0"), self.frozen_plan(build_number="18"),
        ):
            with self.subTest(plan=plan):
                self.github.artifacts.clear()
                self.github.retain(plan.to_bytes())
                with self.assertRaisesRegex(release_plan.ReleaseError, "does not match this workflow run"):
                    self.resolve(attempt=2)

    def test_retrieved_plan_requires_valid_remote_metadata_and_exact_payload(self):
        plan_bytes = self.frozen_plan().to_bytes()
        for field in (
            {"workflow_run": {"id": 999, "head_sha": COMMIT}}, {"size_in_bytes": 0}, {"digest": ""},
        ):
            with self.subTest(field=field):
                self.github.artifacts.clear()
                self.github.retain(plan_bytes, **field)
                with self.assertRaisesRegex(release_plan.ReleaseError, "invalid metadata"):
                    self.resolve(attempt=2)
        self.assertEqual(self.github.downloads, [])

        self.github.artifacts.clear()
        self.github.retain(plan_bytes, digest="sha256:" + "f" * 64)
        with self.assertRaisesRegex(release_plan.ReleaseError, "size or digest"):
            self.resolve(attempt=2)

    def test_multiple_retained_plans_are_rejected(self):
        self.github.retain(self.frozen_plan().to_bytes())
        self.github.retain(self.frozen_plan().to_bytes(), id=1235)
        with self.assertRaisesRegex(release_plan.ReleaseError, "multiple frozen release plans"):
            self.resolve(attempt=2)

    def test_frozen_json_rejects_invalid_keys_types_and_bump_math(self):
        plan = self.frozen_plan()
        contents = plan.to_bytes()
        values = json.loads(contents)
        self.assertEqual(release_plan.ReleasePlan.from_bytes(contents), plan)
        for bad in (
            b"\xff", b"[]", contents.replace(b'{', b'{"version":"1.10.4",', 1),
            json.dumps(values | {"other": "extra"}).encode(),
            json.dumps(values | {"version": "1.10.5"}).encode(),
            json.dumps(values | {"build_number": int(BUILD_NUMBER)}).encode(),
        ):
            with self.subTest(bad=bad), self.assertRaises(release_plan.ReleaseError):
                release_plan.ReleasePlan.from_bytes(bad)

    def test_bare_candidate_tag_fails_fresh_and_defers_same_source_retry_ownership(self):
        self.github.add_release("v1.10.3")
        self.github.tags["v1.10.4"] = {"sha": COMMIT, "type": "commit"}
        with self.assertRaisesRegex(release_plan.ReleaseError, "tag v1.10.4 already exists"):
            self.resolve()
        self.github.retain(self.frozen_plan().to_bytes())
        self.assertEqual(self.resolve(attempt=2).mode, "build")
        self.github.tags["v1.10.4"]["sha"] = PREVIOUS_COMMIT
        with self.assertRaisesRegex(release_plan.ReleaseError, "tag v1.10.4 already exists"):
            self.resolve(attempt=2)

    def test_cli_writes_plan_and_workflow_outputs_on_first_attempt(self):
        self.github.add_release("v1.10.3")
        with tempfile.TemporaryDirectory() as directory:
            plan_file = Path(directory) / release_plan.PLAN_NAME
            output = Path(directory) / "output"
            env = ENVIRONMENT | {"GITHUB_OUTPUT": str(output)}
            with patch.dict(os.environ, env, clear=True), patch("release.GitHub", return_value=self.github):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(release_plan.main(["--plan-file", str(plan_file)]), 0)
            self.assertEqual(plan_file.read_bytes(), self.frozen_plan().to_bytes())
            self.assertEqual(
                output.read_text(), "mode=build\nversion=1.10.4\nbase_tag=v1.10.3\nupload_plan=true\nrelease_url=\n",
            )
