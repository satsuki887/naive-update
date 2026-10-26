import io
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import naive_update as app
from ci.package import package


WORKFLOW = '''name: Build
steps:
  - run: printf 'CADDY_VERSION=%s\\n' "$(<CADDY_VERSION)" >> "$GITHUB_ENV"
  - uses: actions/checkout@v4
    with:
      repository: caddyserver/caddy
      ref: ${{ env.CADDY_VERSION }}
      path: .caddy-bbr
  - run: git -C .caddy-bbr apply "$GITHUB_WORKSPACE/caddy-sing-quic-bbrv1.patch" "$GITHUB_WORKSPACE/caddy-read-idle-timeout.patch"
  - uses: actions/setup-go@v5
    with:
      go-version: ^1.26.x
  - run: go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
  - run: ~/go/bin/xcaddy build "$CADDY_VERSION" --replace "github.com/caddyserver/caddy/v2=$GITHUB_WORKSPACE/.caddy-bbr" --with "github.com/caddyserver/forwardproxy=$GITHUB_WORKSPACE"
'''


class Workspace(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def artifact(self):
        target = self.root / "artifact"
        target.mkdir()
        (target / "caddy").write_bytes(b"new-binary")
        info = {"schema": 1, "release": "v2.11.7-naive2", "goarch": "amd64",
                "forwardproxy": {"repository": app.FORWARD},
                "caddy": {"repository": app.CADDY}, "sha256": app.sha256(target / "caddy")}
        app.atomic_json(target / "build.json", info)
        for name in ("build-info.txt", "LICENSES.txt", "SHA256SUMS"):
            (target / name).write_text("test-only")
        return target, info


class RecipeTests(Workspace):
    def source(self, workflow=WORKFLOW):
        (self.root / ".github/workflows").mkdir(parents=True)
        (self.root / ".github/workflows/build.yml").write_text(workflow)
        (self.root / "CADDY_VERSION").write_text("v2.11.7\n")
        for name in ("caddy-sing-quic-bbrv1.patch", "caddy-read-idle-timeout.patch"):
            (self.root / name).write_text("test patch")

    def test_official_patch_order_and_go_version(self):
        self.source()
        version, patches, go = app.official_plan(self.root)
        self.assertEqual(version, "v2.11.7")
        self.assertEqual(patches, ["caddy-sing-quic-bbrv1.patch", "caddy-read-idle-timeout.patch"])
        self.assertEqual(go, (1, 26))

    def test_unknown_preparation_step_stops(self):
        self.source(WORKFLOW + "\n  - run: ./new-required-step.sh\n")
        with self.assertRaises(app.Failure):
            app.official_plan(self.root)

    def test_traversal_patch_stops(self):
        self.source(WORKFLOW.replace("caddy-read-idle-timeout.patch", "../escape.patch"))
        with self.assertRaises(app.Failure):
            app.official_plan(self.root)

    def test_missing_patch_stops(self):
        self.source()
        (self.root / "caddy-read-idle-timeout.patch").unlink()
        with self.assertRaises(app.Failure):
            app.official_plan(self.root)

    def test_client_version_is_rejected(self):
        with self.assertRaises(app.Failure):
            app.release_tag("v154.0.8037.49-5")

    def test_shell_injection_release_is_rejected(self):
        with self.assertRaises(app.Failure):
            app.release_tag("v2.11.7-naive2;touch /tmp/oops")


class ArtifactTests(Workspace):
    def test_modified_binary_rejected(self):
        target, _ = self.artifact()
        (target / "caddy").write_bytes(b"tampered")
        with self.assertRaises(app.Failure):
            app.verify_artifact(target)

    def test_wrong_source_rejected(self):
        target, info = self.artifact()
        info["forwardproxy"]["repository"] = "https://example.com/fork.git"
        app.atomic_json(target / "build.json", info)
        with self.assertRaises(app.Failure):
            app.verify_artifact(target)

    def test_package_contains_only_required_public_files(self):
        target, _ = self.artifact()
        (target / "Caddyfile").write_text("SECRET_CONFIG_DO_NOT_PUBLISH")
        (target / "build.log").write_text("PRIVATE_LOG_DO_NOT_PUBLISH")
        archive = package(target, self.root / "dist")
        out = self.root / "out"
        out.mkdir()
        app.extract_bundle(archive, out)
        self.assertEqual(len(list(out.iterdir())), 5)
        self.assertFalse((out / "Caddyfile").exists())
        app.verify_artifact(out)

    def test_archive_path_traversal_rejected(self):
        archive = self.root / "evil.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            for name in ("../escape", "build.json", "build-info.txt", "SHA256SUMS", "LICENSES.txt"):
                member = tarfile.TarInfo(name)
                member.size = 1
                stream.addfile(member, io.BytesIO(b"x"))
        with self.assertRaises(app.Failure):
            app.extract_bundle(archive, self.root)
        self.assertFalse((self.root.parent / "escape").exists())

    def test_archive_symlink_rejected(self):
        archive = self.root / "evil.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            for name in ("caddy", "build.json", "build-info.txt", "SHA256SUMS", "LICENSES.txt"):
                member = tarfile.TarInfo(name)
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc/passwd"
                stream.addfile(member)
        with self.assertRaises(app.Failure):
            app.extract_bundle(archive, self.root)


class FakeService:
    def __init__(self, root):
        self.binary = root / "installed-caddy"
        self.binary.write_bytes(b"old-binary")
        self.config = root / "private-config"
        self.config.write_text("secret password")
        self.name = "caddy"
        self.restart_count = 0
        self.fail_new = False
        self.fail_old = False
        self.fail_validation = False
        self.change_config = False

    def inspect(self):
        pass

    def snapshot(self, backup):
        (backup / "unit.snapshot").write_text("fake unit")

    def validate(self, candidate, _log):
        if self.fail_validation:
            raise app.Failure("invalid config")
        if self.change_config:
            self.config.write_text("concurrent change")
        if candidate.read_bytes() not in (b"old-binary", b"new-binary"):
            raise app.Failure("invalid binary")

    def restart(self):
        self.restart_count += 1
        if self.fail_new and self.binary.read_bytes() == b"new-binary":
            raise app.Failure("failed new service")
        if self.fail_old and self.binary.read_bytes() == b"old-binary":
            raise app.Failure("failed recovery service")

    def healthy(self, digest):
        if app.sha256(self.binary) != digest:
            raise app.Failure("wrong running binary")


class TransactionTests(Workspace):
    def setUp(self):
        super().setUp()
        self.service = FakeService(self.root)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.tx = app.Transaction(self.state, self.service)
        self.source = self.root / "new-caddy"
        self.source.write_bytes(b"new-binary")
        # Exercise orchestration on Windows too; actual metadata copy is tested on Linux below.
        self.copier = patch.object(app, "copy_binary", side_effect=lambda s, d, _m: shutil.copyfile(s, d))
        self.copier.start()
        self.addCleanup(self.copier.stop)
        self.mutable = patch.object(app, "assert_mutable")
        self.mutable.start()
        self.addCleanup(self.mutable.stop)

    def test_success_records_receipt_and_keeps_config(self):
        self.tx.activate(self.source, {"release": "v2.11.7-naive2"})
        self.assertEqual(self.service.binary.read_bytes(), b"new-binary")
        self.assertEqual(self.service.config.read_text(), "secret password")
        self.assertEqual(self.service.restart_count, 1)
        self.assertFalse(self.tx.pending.exists())
        receipt = app.load_json(self.tx.receipt)
        self.assertEqual(receipt["sha256"], app.sha256(self.source))
        self.assertTrue((self.state / "backups" / receipt["backup_id"] / "caddy").is_file())

    def test_validation_failure_never_replaces_or_restarts(self):
        self.service.fail_validation = True
        with self.assertRaises(app.Failure):
            self.tx.activate(self.source, {})
        self.assertEqual(self.service.binary.read_bytes(), b"old-binary")
        self.assertEqual(self.service.restart_count, 0)
        self.assertFalse(self.tx.pending.exists())

    def test_failed_restart_restores_old_binary(self):
        self.service.fail_new = True
        with self.assertRaises(app.Failure):
            self.tx.activate(self.source, {})
        self.assertEqual(self.service.binary.read_bytes(), b"old-binary")
        self.assertEqual(self.service.restart_count, 2)
        self.assertFalse(self.tx.pending.exists())
        self.assertFalse(self.tx.receipt.exists())

    def test_previous_receipt_restored_after_failed_restart(self):
        app.atomic_json(self.tx.receipt, {"schema": 1, "build": "old receipt"})
        self.service.fail_new = True
        with self.assertRaises(app.Failure):
            self.tx.activate(self.source, {})
        self.assertEqual(app.load_json(self.tx.receipt)["build"], "old receipt")

    def test_failed_recovery_keeps_journal(self):
        self.service.fail_new = True
        self.service.fail_old = True
        with self.assertRaises(app.Failure):
            self.tx.activate(self.source, {})
        self.assertTrue(self.tx.pending.exists())
        self.service.fail_old = False
        self.tx.recover()
        self.assertFalse(self.tx.pending.exists())
        self.assertEqual(self.service.binary.read_bytes(), b"old-binary")

    def test_pending_transaction_blocks_install(self):
        app.atomic_json(self.tx.pending, {})
        with self.assertRaises(app.Failure):
            self.tx.activate(self.source, {})
        self.assertEqual(self.service.restart_count, 0)

    def test_manual_rollback(self):
        self.tx.activate(self.source, {})
        self.tx.rollback()
        self.assertEqual(self.service.binary.read_bytes(), b"old-binary")
        self.assertEqual(app.load_json(self.tx.receipt)["operation"], "rollback")

    def test_config_changed_during_validation_blocks_swap(self):
        self.service.change_config = True
        with self.assertRaises(app.Failure):
            self.tx.activate(self.source, {})
        self.assertEqual(self.service.binary.read_bytes(), b"old-binary")
        self.assertEqual(self.service.restart_count, 0)

    def test_tampered_backup_blocks_rollback(self):
        self.tx.activate(self.source, {})
        receipt = app.load_json(self.tx.receipt)
        (self.state / "backups" / receipt["backup_id"] / "caddy").write_bytes(b"tampered")
        with self.assertRaises(app.Failure):
            self.tx.rollback()
        self.assertEqual(self.service.binary.read_bytes(), b"new-binary")

    def test_backup_traversal_rejected(self):
        with self.assertRaises(app.Failure):
            self.tx.rollback("../../outside")

    def test_wrong_service_recovery_rejected(self):
        app.atomic_json(self.tx.pending, {"schema": 1, "service": "unrelated"})
        with self.assertRaises(app.Failure):
            self.tx.recover()


@unittest.skipUnless(os.name == "posix", "Linux metadata test")
class LinuxMetadataTests(Workspace):
    def test_copy_preserves_mode_and_user_xattr(self):
        source = self.root / "source"
        source.write_bytes(b"new")
        metadata = self.root / "old"
        metadata.write_bytes(b"old")
        os.chmod(metadata, 0o751)
        xattrs = hasattr(os, "setxattr")
        if xattrs:
            try:
                os.setxattr(metadata, "user.naive-test", b"preserve-me")
            except OSError:
                xattrs = False
        destination = self.root / "destination"
        app.copy_binary(source, destination, metadata)
        self.assertEqual(destination.read_bytes(), b"new")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o751)
        if xattrs:
            self.assertEqual(os.getxattr(destination, "user.naive-test"), b"preserve-me")


if __name__ == "__main__":
    unittest.main()
