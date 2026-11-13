import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "release.py"
SPEC = importlib.util.spec_from_file_location("luma_release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release
SPEC.loader.exec_module(release)


def archive_bytes(context, version=None):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        archive.writestr("Luma Luma.app/Contents/Info.plist", plistlib.dumps({
            "CFBundleIdentifier": "dev.illyes.lumaluma",
            "CFBundleShortVersionString": version or context.version,
            "CFBundleVersion": context.run_number,
        }))
        for name in ("MacOS/LumaLuma", "Helpers/LumaLumaGammaHelper", "Resources/LICENSE", "Resources/LumaLuma.icns"):
            archive.writestr(f"Luma Luma.app/Contents/{name}", b"test fixture")
    return data.getvalue()


class FakeGitHub:
    def __init__(self, context):
        self.context = context
        self.prefix = f"repos/{context.repository}"
        self.release = None
        self.tag_commit = None
        self.asset_contents = {}
        self.next_asset = 10
        self.mutations = []
        self.other_releases = []
        self.upload_failure = False
        self.publish_failure = False

    def api(self, method, path, payload=None, allow_missing=False):
        if path == "graphql":
            candidate = {"databaseId": self.release["id"]} if self.release else None
            return {"data": {"repository": {"release": candidate}}}
        if method != "GET":
            self.mutations.append((method, path, copy.deepcopy(payload)))
        if method == "GET" and "/releases/tags/" in path:
            return copy.deepcopy(self.release) if self.release and not self.release["draft"] else None
        if method == "GET" and path == f"{self.prefix}/releases/1":
            return copy.deepcopy(self.release)
        if method == "GET" and "/git/ref/tags/" in path:
            return {"object": {"sha": self.tag_commit, "type": "commit"}} if self.tag_commit else None
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
        if self.upload_failure:
            self.upload_failure = False
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
        self.context = release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", "3")
        self.github = FakeGitHub(self.context)
        self.publisher = release.ReleasePublisher(self.context, self.github)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.archive = archive_bytes(self.context)
        self.checksum = f"{hashlib.sha256(self.archive).hexdigest()}  {self.context.archive_name}\n".encode()
        (self.directory / self.context.archive_name).write_bytes(self.archive)
        (self.directory / self.context.asset_names[1]).write_bytes(self.checksum)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {}, clear=True).start()
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

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
        self.github.add_asset(self.context.asset_names[0], self.archive)
        self.github.add_asset(self.context.asset_names[1], self.checksum)
        return result

    def test_run_numbers_form_patch_versions(self):
        versions = (("1", "0.1.1"), ("2", "0.1.2"), ("3", "1.0.0"), ("4", "1.0.1"), ("27", "1.0.24"))
        for number, version in versions:
            with self.subTest(number=number):
                self.assertEqual(release.version_for_run(number), version)
        for number in ("0", "01", "-1", "1.0", "x", "1\n"):
            with self.subTest(number=number), self.assertRaises(release.ReleaseError):
                release.version_for_run(number)

    def test_invalid_context_is_rejected(self):
        for values in (
            ("bad repo", "a" * 40, "123", "1"),
            ("o/r", "main", "123", "1"),
            ("o/r", "a" * 40, "0", "1"),
        ):
            with self.subTest(values=values), self.assertRaises(release.ReleaseError):
                release.ReleaseContext(*values)

    def test_prepare_new_version_is_read_only(self):
        self.assertFalse(self.publisher.prepare())
        self.assertEqual(self.github.mutations, [])

    def test_prepare_emits_workflow_outputs(self):
        path = self.directory / "output"
        with patch.dict(os.environ, {"GITHUB_OUTPUT": str(path)}):
            self.publisher.prepare()
        self.assertEqual(path.read_text(), "version=1.0.0\nbuild_number=3\npublished=false\nrelease_url=\n")

    def test_first_publication_creates_complete_release(self):
        self.assertEqual(self.publisher.publish(self.directory), self.context.url)
        self.assertFalse(self.github.release["draft"])
        self.assertEqual(self.github.tag_commit, self.context.commit)
        self.assertEqual(self.github.release["make_latest"], "true")
        self.assertEqual(len(self.github.release["assets"]), 2)

    def test_published_rerun_needs_no_local_artifacts_or_mutations(self):
        self.published()
        self.assertTrue(self.publisher.prepare())
        self.assertEqual(self.publisher.publish(self.directory / "missing"), self.context.url)
        self.assertEqual(self.github.mutations, [])

    def test_legacy_published_reruns_keep_their_release_identity(self):
        for number, version in (("1", "0.1.1"), ("2", "0.1.2")):
            with self.subTest(number=number):
                context = release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", number)
                github = FakeGitHub(context)
                publisher = release.ReleasePublisher(context, github)
                github.release = {
                    "id": 1, "tag_name": f"v{version}", "target_commitish": context.commit,
                    "body": publisher._notes(), "draft": False, "prerelease": False, "assets": [],
                }
                github.tag_commit = context.commit
                archive = archive_bytes(context)
                checksum = f"{hashlib.sha256(archive).hexdigest()}  {context.archive_name}\n".encode()
                github.add_asset(context.archive_name, archive)
                github.add_asset(context.asset_names[1], checksum)
                self.assertTrue(publisher.prepare())
                self.assertEqual(publisher.publish(self.directory / "missing"), context.url)
                self.assertEqual(context.version, version)
                self.assertEqual(github.mutations, [])

    def test_own_draft_is_resumed(self):
        self.draft()
        self.github.add_asset(self.context.archive_name, self.archive)
        self.publisher.publish(self.directory)
        self.assertFalse(any(method == "POST" for method, _, _ in self.github.mutations))
        self.assertEqual(sum(method == "UPLOAD" for method, _, _ in self.github.mutations), 1)

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
        self.github.upload_failure = True
        with self.assertRaisesRegex(release.ReleaseError, "Upload interrupted"):
            self.publisher.publish(self.directory)
        self.assertTrue(self.github.release["draft"])
        self.assertEqual(self.github.release["assets"][0]["state"], "starter")
        self.assertFalse(self.publisher.prepare())
        self.publisher.publish(self.directory)
        self.assertFalse(self.github.release["draft"])
        self.assertTrue(any(method == "DELETE" for method, _, _ in self.github.mutations))

    def test_wrong_asset_in_own_draft_is_replaced(self):
        self.draft()
        self.github.add_asset(self.context.archive_name, b"previous incomplete output")
        self.publisher.publish(self.directory)
        self.assertTrue(any(method == "DELETE" for method, _, _ in self.github.mutations))

    def test_publication_failure_leaves_verified_draft(self):
        self.github.publish_failure = True
        with self.assertRaisesRegex(release.ReleaseError, "Publication failed"):
            self.publisher.publish(self.directory)
        self.assertTrue(self.github.release["draft"])
        self.assertEqual(len(self.github.release["assets"]), 2)
        self.github.publish_failure = False
        self.github.mutations.clear()
        self.publisher.publish(self.directory)
        self.assertFalse(any(method == "UPLOAD" for method, _, _ in self.github.mutations))

    def test_foreign_release_is_rejected(self):
        self.draft()["body"] = "Created by someone else"
        with self.assertRaisesRegex(release.ReleaseError, "owned"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_foreign_run_marker_is_rejected(self):
        self.draft()["body"] = self.publisher._notes().replace('"run_id":"123"', '"run_id":"124"')
        with self.assertRaisesRegex(release.ReleaseError, "owned"):
            self.publisher.prepare()

    def test_duplicate_marker_is_rejected(self):
        self.draft()["body"] = self.publisher._notes() * 2
        with self.assertRaises(release.ReleaseError):
            self.publisher.prepare()

    def test_existing_unowned_tag_is_rejected(self):
        self.github.tag_commit = self.context.commit
        with self.assertRaisesRegex(release.ReleaseError, "already exists"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_read_only_prepare_defers_invisible_same_commit_draft(self):
        self.github.tag_commit = self.context.commit
        self.assertFalse(self.publisher.prepare())
        self.assertEqual(self.github.mutations, [])
        self.draft()
        self.publisher.publish(self.directory)
        self.assertFalse(self.github.release["draft"])

    def test_deferred_foreign_same_commit_tag_is_rejected_by_publisher(self):
        self.github.tag_commit = self.context.commit
        self.assertFalse(self.publisher.prepare())
        with self.assertRaisesRegex(release.ReleaseError, "already exists"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_read_only_prepare_rejects_different_commit_tag(self):
        self.github.tag_commit = "b" * 40
        with self.assertRaisesRegex(release.ReleaseError, "different commit"):
            self.publisher.prepare()

    def test_wrong_tag_commit_is_rejected(self):
        self.published()
        self.github.tag_commit = "b" * 40
        with self.assertRaisesRegex(release.ReleaseError, "tag targets"):
            self.publisher.prepare()

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
        self.assertTrue(self.publisher.prepare())

    def test_annotated_tag_cycle_is_rejected(self):
        self.published()
        original = self.github.api
        def cyclic_api(method, path, payload=None, allow_missing=False):
            if "/git/ref/tags/" in path or "/git/tags/" in path:
                return {"object": {"type": "tag", "sha": "b" * 40}}
            return original(method, path, payload, allow_missing)
        self.github.api = cyclic_api
        with self.assertRaisesRegex(release.ReleaseError, "cycle"):
            self.publisher.prepare()

    def test_draft_changed_after_asset_deletion_stops_upload(self):
        self.draft()
        self.github.add_asset(self.context.archive_name, b"old")
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
            self.publisher.prepare()

    def test_unexpected_asset_is_preserved_and_rejected(self):
        self.draft()
        self.github.add_asset("personal-file.txt", b"keep")
        with self.assertRaisesRegex(release.ReleaseError, "unexpected"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])
        self.assertEqual(len(self.github.release["assets"]), 1)

    def test_corrupt_published_data_is_rejected_without_repair(self):
        self.published()
        asset = self.github.release["assets"][0]
        self.github.asset_contents[asset["id"]] = b"bad"
        with self.assertRaises(release.ReleaseError):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_missing_published_asset_is_rejected(self):
        self.published()["assets"].pop()
        with self.assertRaisesRegex(release.ReleaseError, "missing"):
            self.publisher.prepare()

    def test_local_wrong_checksum_stops_before_mutation(self):
        (self.directory / self.context.asset_names[1]).write_text("0" * 64 + f"  {self.context.archive_name}\n")
        with self.assertRaisesRegex(release.ReleaseError, "checksum"):
            self.publisher.publish(self.directory)
        self.assertEqual(self.github.mutations, [])

    def test_wrong_bundle_version_is_rejected(self):
        data = archive_bytes(self.context, version="9.9.9")
        checksum = f"{hashlib.sha256(data).hexdigest()}  {self.context.archive_name}\n".encode()
        with self.assertRaisesRegex(release.ReleaseError, "version"):
            release.verify_archive(self.context, data, checksum)

    def test_newer_published_version_remains_latest(self):
        self.github.other_releases = [{"tag_name": "v1.0.1", "draft": False, "prerelease": False}]
        self.publisher.publish(self.directory)
        self.assertEqual(self.github.release["make_latest"], "false")

    def test_stable_release_becomes_latest_after_development_series(self):
        self.github.other_releases = [{"tag_name": "v0.1.99", "draft": False, "prerelease": False}]
        self.publisher.publish(self.directory)
        self.assertEqual(self.github.release["make_latest"], "true")

    def test_legacy_release_cannot_displace_stable_latest(self):
        context = release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", "2")
        publisher = release.ReleasePublisher(context, self.github)
        self.github.other_releases = [{"tag_name": "v1.0.0", "draft": False, "prerelease": False}]
        self.assertEqual(publisher._make_latest(), "false")

    def test_drafts_and_prereleases_do_not_suppress_latest(self):
        self.github.other_releases = [
            {"tag_name": "v9.0.0", "draft": True, "prerelease": False},
            {"tag_name": "v9.1.0", "draft": False, "prerelease": True},
        ]
        self.publisher.publish(self.directory)
        self.assertEqual(self.github.release["make_latest"], "true")

    def test_latest_uses_numeric_version_order(self):
        context = release.ReleaseContext("ill-yes/luma-luma", "a" * 40, "123", "12")
        publisher = release.ReleasePublisher(context, self.github)
        self.github.other_releases = [{"tag_name": "v1.0.10", "draft": False, "prerelease": False}]
        self.assertEqual(publisher._make_latest(), "false")

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
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "HTTP 404")):
            self.assertIsNone(github.api("GET", "example", allow_missing=True))


if __name__ == "__main__":
    unittest.main()
