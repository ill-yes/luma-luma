import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "release.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("luma_release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)


def disk_image_bytes(context, target, **overrides):
    metadata = {"version": context.version, "build_number": context.run_number, "architecture": target}
    metadata.update(overrides)
    return json.dumps(metadata).encode()


def checksum_bytes(name, image):
    return f"{hashlib.sha256(image).hexdigest()}  {name}\n".encode()


class FakeGitHub:
    def __init__(self, context):
        self.context = context
        self.prefix = f"repos/{context.repository}"
        self.release = None
        self.tags = {}
        self.comparisons = {}
        self.asset_contents = {}
        self.next_asset = 10
        self.mutations = []
        self.other_releases = []
        self.upload_failure = None
        self.publish_failure = False

    @property
    def tag_commit(self):
        return self.tags.get(self.context.tag)

    @tag_commit.setter
    def tag_commit(self, sha):
        self.tags[self.context.tag] = sha

    def add_published_release(self, tag, sha):
        self.tags[tag] = sha
        self.other_releases.append({"tag_name": tag, "draft": False, "prerelease": False})

    def api(self, method, path, payload=None, allow_missing=False):
        if path == "graphql":
            candidate = {"databaseId": self.release["id"]} if self.release else None
            return {"data": {"repository": {"release": candidate}}}
        if method != "GET":
            self.mutations.append((method, path, copy.deepcopy(payload)))
        if method == "GET" and "/releases/tags/" in path:
            tag = path.rsplit("/", 1)[1]
            return next((item for item in self.releases() if item["tag_name"] == tag and not item["draft"]), None)
        if method == "GET" and path == f"{self.prefix}/releases/1":
            return copy.deepcopy(self.release)
        if method == "GET" and "/git/ref/tags/" in path:
            sha = self.tags.get(path.rsplit("/", 1)[1])
            return {"object": {"sha": sha, "type": "commit"}} if sha else None
        if method == "GET" and "/compare/" in path:
            return self.comparisons.get(path.rsplit("/", 1)[1], {"status": "ahead", "commits": []})
        if method == "POST":
            self.release = {**payload, "id": 1, "assets": []}
            return copy.deepcopy(self.release)
        if method == "DELETE":
            asset_id = int(path.rsplit("/", 1)[1])
            self.release["assets"] = [asset for asset in self.release["assets"] if asset["id"] != asset_id]
            self.asset_contents.pop(asset_id, None)
            return None
        if method == "PATCH":
            if self.publish_failure:
                raise release.ReleaseError("Publication failed")
            self.release.update(payload)
            self.tag_commit = self.context.commit
            return copy.deepcopy(self.release)
        raise AssertionError((method, path, payload))

    def releases(self):
        return copy.deepcopy(self.other_releases + ([self.release] if self.release else []))

    def download(self, asset_id):
        return self.asset_contents[asset_id]

    def upload(self, release_id, path):
        self.mutations.append(("UPLOAD", path.name, None))
        if self.upload_failure == path.name:
            self.upload_failure = None
            self.add_asset(path.name, b"", state="starter")
            raise release.ReleaseError("Upload interrupted")
        return self.add_asset(path.name, path.read_bytes())

    def add_asset(self, name, contents, state="uploaded"):
        asset = {"id": self.next_asset, "name": name, "size": len(contents), "state": state}
        self.next_asset += 1
        self.release["assets"].append(asset)
        self.asset_contents[asset["id"]] = contents
        return asset


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.context = release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", "3", "1.0.0")
        self.github = FakeGitHub(self.context)
        self.image_verifications = []
        self.publisher = release.ReleasePublisher(self.context, self.github, image_verifier=self.inspect_image)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.assets = {}
        for architecture, name in self.context.disk_images.items():
            image = disk_image_bytes(self.context, architecture)
            self.assets[name] = image
            self.assets[f"{name}.sha256"] = checksum_bytes(name, image)
        for name, contents in self.assets.items():
            (self.directory / name).write_bytes(contents)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {}, clear=True).start()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def inspect_image(self, path, version, build_number, architecture):
        self.image_verifications.append(path)
        image = json.loads(path.read_bytes())
        for key, value in (("version", version), ("build_number", build_number), ("architecture", architecture)):
            if image[key] != value:
                raise release.ReleaseError(f"Wrong {key} in {path.name}")

    def draft(self):
        self.github.release = {
            "id": 1, "tag_name": self.context.tag, "target_commitish": self.context.commit,
            "body": self.publisher._notes(), "draft": True, "prerelease": False, "assets": [],
        }
        return self.github.release

    def published(self):
        result = self.draft()
        result["draft"] = False
        self.github.tag_commit = self.context.commit
        for name, contents in self.assets.items():
            self.github.add_asset(name, contents)
        return result

    def test_build_numbers_do_not_select_the_release_version(self):
        versions = (("1", "0.1.1"), ("2", "1.0.0"), ("3", "3.0.0"), ("27", "3.10.4"))
        for number, version in versions:
            with self.subTest(number=number):
                context = release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", number, version)
                self.assertEqual(context.tag, f"v{version}")
                self.assertEqual(context.run_number, number)
        for number in ("0", "01", "-1", "1.0", "x", "1\n"):
            with self.subTest(number=number), self.assertRaises(release.ReleaseError):
                release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", number, "1.0.0")

    def test_invalid_context_is_rejected(self):
        for values in (
            ("bad repo", "a" * 40, "123", "1", "1.0.0"),
            ("o/r", "main", "123", "1", "1.0.0"),
            ("o/r", "a" * 40, "0", "1", "1.0.0"),
            ("o/r", "a" * 40, "123", "1", "1.0.00"),
            ("o/r", "a" * 40, "123", "1", "v1.0.0"),
        ):
            with self.subTest(values=values), self.assertRaises(release.ReleaseError):
                release.ReleaseContext(*values)

    def test_environment_requires_main_and_frozen_version(self):
        env = {
            "GITHUB_REPOSITORY": "ill-yes/luma-luma",
            "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123",
            "GITHUB_RUN_NUMBER": "3",
            "RELEASE_VERSION": "1.0.0",
        }
        with patch.dict(os.environ, {**env, "GITHUB_REF": "refs/heads/feature"}):
            with self.assertRaisesRegex(release.ReleaseError, "from main"):
                release.ReleaseContext.from_environment()
        with patch.dict(os.environ, {**env, "GITHUB_REF": "refs/heads/main"}):
            self.assertEqual(release.ReleaseContext.from_environment(), self.context)
            del os.environ["RELEASE_VERSION"]
            with self.assertRaisesRegex(release.ReleaseError, "RELEASE_VERSION"):
                release.ReleaseContext.from_environment()

    def test_preflight_new_version_is_read_only(self):
        self.assertFalse(self.publisher.preflight())
        self.assertEqual(self.github.mutations, [])

    def test_preflight_emits_workflow_outputs(self):
        path = self.directory / "output"
        with patch.dict(os.environ, {"GITHUB_OUTPUT": str(path)}):
            self.publisher.preflight()
        self.assertEqual(path.read_text(), "version=1.0.0\nbuild_number=3\npublished=false\nrelease_url=\n")

    def test_first_publication_creates_complete_release(self):
        self.assertEqual(self.publisher.publish(self.directory), self.context.url)
        self.assertFalse(self.github.release["draft"])
        self.assertEqual(self.github.tag_commit, self.context.commit)
        self.assertEqual(self.github.release["make_latest"], "true")
        self.assertEqual(set(asset["name"] for asset in self.github.release["assets"]), set(self.assets))
        self.assertEqual(self.image_verifications, [self.directory / name for name in self.context.disk_images.values()])

    def test_release_has_architecture_specific_asset_names(self):
        self.assertEqual(self.context.asset_names, (
            "LumaLuma-1.0.0-macos-arm64.dmg", "LumaLuma-1.0.0-macos-arm64.dmg.sha256",
            "LumaLuma-1.0.0-macos-x86_64.dmg", "LumaLuma-1.0.0-macos-x86_64.dmg.sha256",
        ))

    def test_published_summary_includes_both_image_checksums(self):
        summary = self.directory / "summary"
        with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
            self.publisher.publish(self.directory)
        for name in self.context.disk_images.values():
            self.assertIn(f"`{name}` · SHA-256 `{hashlib.sha256(self.assets[name]).hexdigest()}`", summary.read_text())

    def test_published_rerun_needs_no_local_artifacts_or_mutations(self):
        self.published()
        self.assertTrue(self.publisher.preflight())
        self.assertEqual(self.publisher.publish(self.directory / "missing"), self.context.url)
        self.assertEqual(self.github.mutations, [])
        self.assertEqual([path.name for path in self.image_verifications], list(self.context.disk_images.values()) * 2)
        self.assertFalse(any(path.exists() for path in self.image_verifications))

    def test_own_draft_is_resumed(self):
        self.draft()
        first_asset = self.context.asset_names[0]
        self.github.add_asset(first_asset, self.assets[first_asset])
        self.publisher.publish(self.directory)
        self.assertFalse(any(method == "POST" for method, _, _ in self.github.mutations))
        uploaded = [name for method, name, _ in self.github.mutations if method == "UPLOAD"]
        self.assertEqual(uploaded, list(self.context.asset_names[1:]))

    def test_draft_lookup_uses_release_list_and_id(self):
        draft = self.draft()
        self.assertIsNone(self.github.api("GET", f"{self.github.prefix}/releases/tags/{self.context.tag}"))
        self.assertEqual(self.publisher._load_release()["id"], draft["id"])
        self.assertEqual(self.github.mutations, [])

    def test_draft_lookup_uses_graphql_when_rest_list_lags(self):
        draft = self.draft()
        self.github.releases = lambda: []
        self.assertEqual(self.publisher._load_release()["id"], draft["id"])
        self.assertEqual(self.github.mutations, [])

    def test_new_draft_is_reloaded_by_id_when_rest_list_lags(self):
        self.github.releases = lambda: []
        self.publisher.publish(self.directory)
        self.assertFalse(self.github.release["draft"])
        self.assertEqual(sum(method == "POST" for method, _, _ in self.github.mutations), 1)

    def test_transient_id_404_is_retried_without_creating_another_draft(self):
        original = self.github.api
        remaining_failures = 2
        def api(method, path, payload=None, allow_missing=False):
            nonlocal remaining_failures
            if method == "GET" and path == f"{self.github.prefix}/releases/1" and remaining_failures:
                remaining_failures -= 1
                return None
            return original(method, path, payload, allow_missing)
        self.github.api = api
        with patch.object(release.time, "sleep"):
            self.publisher.publish(self.directory)
        self.assertEqual(sum(method == "POST" for method, _, _ in self.github.mutations), 1)
        self.assertFalse(self.github.release["draft"])

    def test_persistent_id_404_stops_without_creating_another_draft(self):
        original = self.github.api
        def api(method, path, payload=None, allow_missing=False):
            if method == "GET" and path == f"{self.github.prefix}/releases/1":
                return None
            return original(method, path, payload, allow_missing)
        self.github.api = api
        with patch.object(release.time, "sleep"), self.assertRaisesRegex(release.ReleaseError, "known release"):
            self.publisher.publish(self.directory)
        self.assertEqual(sum(method == "POST" for method, _, _ in self.github.mutations), 1)
        self.assertFalse(any(method == "UPLOAD" for method, _, _ in self.github.mutations))

    def test_graphql_error_stops_before_release_creation(self):
        original = self.github.api
        def api(method, path, payload=None, allow_missing=False):
            if path == "graphql":
                return {"errors": [{"message": "Forbidden"}]}
            return original(method, path, payload, allow_missing)
        self.github.api = api
        with self.assertRaisesRegex(release.ReleaseError, "metadata"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_duplicate_drafts_for_version_are_rejected(self):
        self.draft()
        self.github.other_releases = [{"id": 2, "tag_name": self.context.tag, "draft": True}]
        with self.assertRaisesRegex(release.ReleaseError, "Multiple releases"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_interrupted_upload_is_repaired_on_retry(self):
        intel_image = self.context.disk_images["x86_64"]
        self.github.upload_failure = intel_image
        with self.assertRaisesRegex(release.ReleaseError, "Upload interrupted"):
            self.publisher.publish(self.directory)
        self.assertTrue(self.github.release["draft"])
        assets = {asset["name"]: asset for asset in self.github.release["assets"]}
        self.assertEqual(assets[intel_image]["state"], "starter")
        self.assertFalse(self.publisher.preflight())
        self.github.mutations.clear()
        self.publisher.publish(self.directory)
        self.assertFalse(self.github.release["draft"])
        self.assertTrue(any(method == "DELETE" for method, _, _ in self.github.mutations))
        uploaded = [name for method, name, _ in self.github.mutations if method == "UPLOAD"]
        self.assertEqual(uploaded, [intel_image, f"{intel_image}.sha256"])

    def test_wrong_asset_in_own_draft_is_replaced(self):
        self.draft()
        self.github.add_asset(self.context.disk_images["arm64"], b"previous incomplete output")
        self.publisher.publish(self.directory)
        self.assertTrue(any(method == "DELETE" for method, _, _ in self.github.mutations))

    def test_publication_failure_leaves_verified_draft(self):
        self.github.publish_failure = True
        with self.assertRaisesRegex(release.ReleaseError, "Publication failed"):
            self.publisher.publish(self.directory)
        self.assertTrue(self.github.release["draft"])
        self.assertEqual(len(self.github.release["assets"]), 4)
        self.github.publish_failure = False
        self.github.mutations.clear()
        self.publisher.publish(self.directory)
        self.assertFalse(any(method == "UPLOAD" for method, _, _ in self.github.mutations))

    def test_publication_polls_by_id_for_delayed_readback(self):
        original = self.github.api
        patch_seen = False
        reads = 0

        def lagging_api(method, path, payload=None, allow_missing=False):
            nonlocal patch_seen, reads
            result = original(method, path, payload, allow_missing)
            if method == "PATCH":
                patch_seen = True
            if patch_seen and method == "GET" and path == f"{self.github.prefix}/releases/1":
                reads += 1
                if reads == 1:
                    return None
                if reads == 2:
                    result["draft"] = True
            if patch_seen and reads == 3 and "/git/ref/tags/" in path:
                return None
            return result

        self.github.api = lagging_api
        with patch.object(release.time, "sleep"):
            self.assertEqual(self.publisher.publish(self.directory), self.context.url)
        self.assertEqual(reads, 4)
        self.assertEqual(sum(method == "PATCH" for method, _, _ in self.github.mutations), 1)

    def test_publication_readback_does_not_retry_wrong_tag_commit(self):
        original = self.github.api

        def retargeting_api(method, path, payload=None, allow_missing=False):
            result = original(method, path, payload, allow_missing)
            if method == "PATCH":
                self.github.tag_commit = "b" * 40
            return result

        self.github.api = retargeting_api
        with patch.object(release.time, "sleep") as sleep:
            with self.assertRaisesRegex(release.ReleaseError, "different commit"):
                self.publisher.publish(self.directory)
        sleep.assert_not_called()
        self.assertEqual(sum(method == "PATCH" for method, _, _ in self.github.mutations), 1)

    def test_uploaded_bytes_must_match_the_verified_local_images(self):
        name = self.context.disk_images["x86_64"]
        original_upload = self.github.upload

        def upload(release_id, path):
            asset = original_upload(release_id, path)
            if path.name == name:
                self.github.asset_contents[asset["id"]] = b"x" + self.assets[name][1:]
            return asset

        self.github.upload = upload
        with self.assertRaisesRegex(release.ReleaseError, "differs from the local artifact"):
            self.publisher.publish(self.directory)
        self.assertTrue(self.github.release["draft"])
        self.assertFalse(any(method == "PATCH" for method, _, _ in self.github.mutations))

    def test_verified_draft_asset_ids_are_rechecked_before_publication(self):
        original_download = self.github.download

        def replacing_download(asset_id):
            data = original_download(asset_id)
            last_asset = self.github.release["assets"][-1]
            if last_asset["name"] == self.context.asset_names[-1] and asset_id == last_asset["id"]:
                self.github.release["assets"].pop()
                self.github.add_asset(last_asset["name"], data)
            return data

        self.github.download = replacing_download
        with self.assertRaisesRegex(release.ReleaseError, "verified draft assets changed"):
            self.publisher.publish(self.directory)
        self.assertTrue(self.github.release["draft"])
        self.assertFalse(any(method == "PATCH" for method, _, _ in self.github.mutations))

    def test_stable_version_is_rechecked_after_draft_uploads(self):
        original_download = self.github.download

        def publishing_download(asset_id):
            if not self.github.other_releases:
                self.github.add_published_release("v1.0.1", "b" * 40)
            return original_download(asset_id)

        self.github.download = publishing_download
        with self.assertRaisesRegex(release.ReleaseError, "no longer newer"):
            self.publisher.publish(self.directory)
        self.assertTrue(self.github.release["draft"])
        self.assertFalse(any(method == "PATCH" for method, _, _ in self.github.mutations))

    def test_foreign_release_is_rejected(self):
        self.draft()["body"] = "Created by someone else"
        with self.assertRaisesRegex(release.ReleaseError, "owned"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_foreign_run_marker_is_rejected(self):
        self.draft()["body"] = self.publisher._notes().replace('"run_id":"123"', '"run_id":"124"')
        with self.assertRaisesRegex(release.ReleaseError, r"v1\.0\.0 is owned.*actions/runs/124"):
            self.publisher.preflight()

    def test_duplicate_marker_is_rejected(self):
        self.draft()["body"] = self.publisher._notes() * 2
        with self.assertRaises(release.ReleaseError):
            self.publisher.preflight()

    def test_existing_unowned_tag_is_rejected(self):
        self.github.tag_commit = self.context.commit
        with self.assertRaisesRegex(release.ReleaseError, "already exists"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_owned_draft_with_matching_git_tag_is_resumed(self):
        self.github.tag_commit = self.context.commit
        self.draft()
        self.assertFalse(self.publisher.preflight())
        self.assertEqual(self.github.mutations, [])
        self.publisher.publish(self.directory)
        self.assertFalse(self.github.release["draft"])

    def test_preflight_rejects_unowned_same_commit_tag(self):
        self.github.tag_commit = self.context.commit
        with self.assertRaisesRegex(release.ReleaseError, "already exists"):
            self.publisher.preflight()
        self.assertEqual(self.github.mutations, [])

    def test_preflight_rejects_different_commit_tag(self):
        self.github.tag_commit = "b" * 40
        with self.assertRaisesRegex(release.ReleaseError, "different commit"):
            self.publisher.preflight()

    def test_wrong_tag_commit_is_rejected(self):
        self.published()
        self.github.tag_commit = "b" * 40
        with self.assertRaisesRegex(release.ReleaseError, "tag targets"):
            self.publisher.preflight()

    def test_annotated_tag_is_resolved_to_its_commit(self):
        self.published()
        original = self.github.api
        def annotated_api(method, path, payload=None, allow_missing=False):
            if "/git/ref/tags/" in path:
                return {"object": {"type": "tag", "sha": "b" * 40}}
            if "/git/tags/" in path:
                return {"object": {"type": "commit", "sha": self.context.commit}}
            return original(method, path, payload, allow_missing)
        self.github.api = annotated_api
        self.assertTrue(self.publisher.preflight())

    def test_annotated_tag_cycle_is_rejected(self):
        self.published()
        original = self.github.api
        def cyclic_api(method, path, payload=None, allow_missing=False):
            if "/git/ref/tags/" in path or "/git/tags/" in path:
                return {"object": {"type": "tag", "sha": "b" * 40}}
            return original(method, path, payload, allow_missing)
        self.github.api = cyclic_api
        with self.assertRaisesRegex(release.ReleaseError, "cycle"):
            self.publisher.preflight()

    def test_draft_changed_after_asset_deletion_stops_upload(self):
        self.draft()
        self.github.add_asset(self.context.disk_images["arm64"], b"old")
        original = self.github.api
        def changed_api(method, path, payload=None, allow_missing=False):
            result = original(method, path, payload, allow_missing)
            if method == "DELETE":
                self.github.release["body"] = "Ownership changed"
            return result
        self.github.api = changed_api
        with self.assertRaisesRegex(release.ReleaseError, "owned"):
            self.publisher.publish(self.directory)
        self.assertFalse(any(method == "UPLOAD" for method, _, _ in self.github.mutations))

    def test_wrong_release_target_is_rejected(self):
        self.draft()["target_commitish"] = "b" * 40
        with self.assertRaisesRegex(release.ReleaseError, "different commit"):
            self.publisher.preflight()

    def test_unexpected_asset_is_preserved_and_rejected(self):
        self.draft()
        self.github.add_asset("personal-file.txt", b"keep")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])
        self.assertEqual(len(self.github.release["assets"]), 1)

    def test_corrupt_published_data_is_rejected_without_repair(self):
        self.published()
        name = self.context.disk_images["x86_64"]
        intel_image = next(asset for asset in self.github.release["assets"] if asset["name"] == name)
        self.github.asset_contents[intel_image["id"]] = b"x" + self.assets[name][1:]
        with self.assertRaisesRegex(release.ReleaseError, "checksum"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_missing_published_asset_is_rejected(self):
        self.published()["assets"].pop()
        with self.assertRaisesRegex(release.ReleaseError, "missing"):
            self.publisher.preflight()

    def test_local_wrong_checksum_stops_before_mutation(self):
        name = self.context.disk_images["x86_64"]
        (self.directory / f"{name}.sha256").write_text("0" * 64 + f"  {name}\n")
        with self.assertRaisesRegex(release.ReleaseError, "checksum"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])
        self.assertEqual(self.image_verifications, [])

    def test_checksum_cannot_name_another_disk_image(self):
        name = self.context.disk_images["x86_64"]
        other_name = self.context.disk_images["arm64"]
        (self.directory / f"{name}.sha256").write_bytes(checksum_bytes(other_name, self.assets[name]))
        with self.assertRaisesRegex(release.ReleaseError, "checksum must name"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_missing_local_checksum_stops_before_mutation(self):
        (self.directory / f"{self.context.disk_images['x86_64']}.sha256").unlink()
        with self.assertRaisesRegex(release.ReleaseError, "local release"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_wrong_disk_image_version_or_architecture_stops_before_mutation(self):
        name = self.context.disk_images["x86_64"]
        for field, value in (("version", "9.9.9"), ("build_number", "99"), ("architecture", "arm64")):
            with self.subTest(field=field):
                image = disk_image_bytes(self.context, "x86_64", **{field: value})
                (self.directory / name).write_bytes(image)
                (self.directory / f"{name}.sha256").write_bytes(checksum_bytes(name, image))
                with self.assertRaisesRegex(release.ReleaseError, field):
                    self.publisher.publish(self.directory)
                self.assertEqual(self.github.mutations, [])

    def test_published_image_is_inspected_after_checksum_passes(self):
        name = self.context.disk_images["x86_64"]
        self.assets[name] = disk_image_bytes(self.context, "x86_64", version="9.9.9")
        self.assets[f"{name}.sha256"] = checksum_bytes(name, self.assets[name])
        self.published()
        with self.assertRaisesRegex(release.ReleaseError, "version"):
            self.publisher.preflight()
        self.assertEqual(self.github.mutations, [])
        self.assertFalse(any(path.exists() for path in self.image_verifications))

    def test_verifier_invokes_platform_script_and_handles_failure(self):
        path = self.directory / self.context.disk_images["arm64"]
        command = [str(SCRIPT.with_name("verify-dmg.sh")), str(path.resolve()), "1.0.0", "3", "arm64"]
        with patch.object(subprocess, "run", side_effect=subprocess.CalledProcessError(1, command)) as run:
            with self.assertRaisesRegex(release.ReleaseError, "Disk image verification failed"):
                release.verify_disk_image(path, "1.0.0", "3", "arm64")
        run.assert_called_once_with(command, check=True)

    def test_newer_published_version_remains_latest(self):
        self.github.add_published_release("v1.0.1", "b" * 40)
        for command in (self.publisher.preflight, lambda: self.publisher.publish(self.directory)):
            with self.assertRaisesRegex(release.ReleaseError, "no longer newer"):
                command()
        self.assertEqual(self.github.mutations, [])

    def test_stable_release_becomes_latest_after_development_series(self):
        self.github.add_published_release("v0.1.99", "b" * 40)
        self.publisher.publish(self.directory)
        self.assertEqual(self.github.release["make_latest"], "true")

    def test_candidate_must_descend_from_latest_published_tag(self):
        base = "b" * 40
        self.github.add_published_release("v0.9.0", base)
        self.github.comparisons[f"{base}...{self.context.commit}"] = {"status": "diverged"}
        with self.assertRaisesRegex(release.ReleaseError, "must descend"):
            self.publisher.preflight()
        self.assertEqual(self.github.mutations, [])

    def test_later_foreign_stable_release_for_the_same_commit_is_reported(self):
        latest_tag = "v1.0.1"
        self.github.add_published_release(latest_tag, self.context.commit)
        output = self.directory / "output"
        url = f"https://github.com/{self.context.repository}/releases/tag/{latest_tag}"
        with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}):
            self.assertTrue(self.publisher.preflight())
        self.assertIn(f"published=true\nrelease_url={url}\n", output.read_text())
        self.assertEqual(self.publisher.publish(self.directory / "missing"), url)
        self.assertEqual(self.github.mutations, [])

    def test_foreign_stable_release_for_the_same_tag_and_commit_is_reported(self):
        self.github.add_published_release(self.context.tag, self.context.commit)
        self.assertTrue(self.publisher.preflight())
        self.assertEqual(self.publisher.publish(self.directory / "missing"), self.context.url)
        self.assertEqual(self.github.mutations, [])

    def test_drafts_and_prereleases_do_not_suppress_latest(self):
        self.github.other_releases = [
            {"tag_name": "v9.0.0", "draft": True, "prerelease": False},
            {"tag_name": "v9.1.0", "draft": False, "prerelease": True},
        ]
        self.publisher.publish(self.directory)
        self.assertEqual(self.github.release["make_latest"], "true")

    def test_latest_uses_numeric_version_order(self):
        context = release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", "12", "1.0.9")
        publisher = release.ReleasePublisher(context, self.github)
        self.github.add_published_release("v1.0.10", "b" * 40)
        with self.assertRaisesRegex(release.ReleaseError, "no longer newer than v1.0.10"):
            publisher.preflight()

    def test_base_tag_must_be_an_older_stable_tag(self):
        for tag in ("0.9.0", "v0.09.0", "v0.9.0-rc", "v1.0.0", "v2.0.0"):
            with self.subTest(tag=tag), self.assertRaises(release.ReleaseError):
                release.ReleasePublisher(self.context, self.github, base_tag=tag)

    def test_notes_use_frozen_base_and_limit_commit_subjects(self):
        base_tag = "v0.8.0"
        base = "b" * 40
        self.github.add_published_release(base_tag, base)
        self.github.add_published_release("v0.9.0", "c" * 40)
        self.github.comparisons[f"{base}...{self.context.commit}"] = {
            "status": "ahead",
            "commits": [{"commit": {"message": f"Subject {number} <draft>\n\nCommit body"}}
                        for number in range(21)],
        }
        publisher = release.ReleasePublisher(self.context, self.github, base_tag=base_tag)
        notes = publisher._notes()
        self.assertIn(f"/compare/{base_tag}...{self.context.commit}", notes)
        self.assertIn("Subject 19 &lt;draft&gt;", notes)
        self.assertNotIn("Subject 20", notes)
        self.assertNotIn("Commit body", notes)
        self.assertEqual(self.github.mutations, [])

    def test_github_release_pages_are_flattened(self):
        github = release.GitHub(self.context.repository)
        with patch.object(github, "_run", return_value='[[{"id":1}],[{"id":2}]]') as command:
            self.assertEqual(github.releases(), [{"id": 1}, {"id": 2}])
        self.assertIn("--paginate", command.call_args.args[0])
        self.assertIn("--slurp", command.call_args.args[0])

    def test_api_errors_are_redacted_and_missing_is_distinct(self):
        github = release.GitHub(self.context.repository)
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "secret-token HTTP 403")):
            with self.assertRaises(release.ReleaseError) as caught:
                github.api("GET", "example", allow_missing=True)
            self.assertNotIn("secret-token", str(caught.exception))
            self.assertIn("GET example failed (HTTP 403)", str(caught.exception))
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "HTTP 404")):
            self.assertIsNone(github.api("GET", "example", allow_missing=True))


if __name__ == "__main__":
    unittest.main()
