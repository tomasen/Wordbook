#!/usr/bin/env python3

from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS_DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import install_content_pack as installer  # noqa: E402
import install_signed_content_release as signed  # noqa: E402
import test_install_content_pack as pack_tests  # noqa: E402


class InstallSignedContentReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.pack = self.root / "release.sqlite"
        self.destination = self.root / "Shared/wordbook-content.sqlite"
        self.manifest_path = self.root / "release-manifest.json"
        self.key = self.root / "release-key"
        self.allowed_signers = self.root / "allowed_signers"
        self.identity = "wordbook-release-test"
        pack_tests.InstallContentPackTests.create_pack(self, self.pack)

        generated = subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                "test-only",
                "-f",
                str(self.key),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if generated.returncode != 0:
            self.fail(generated.stderr or generated.stdout)
        public_key = self.key.with_suffix(".pub").read_text(encoding="utf-8").strip()
        public_fields = public_key.split()
        self.key_id = "ssh-ed25519-sha256:" + hashlib.sha256(
            base64.b64decode(public_fields[1], validate=True)
        ).hexdigest()
        self.allowed_signers.write_text(
            f"{self.identity} {public_key}\n", encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def manifest(
        self,
        *,
        pack: Path | None = None,
        release_sequence: int = 42,
        rollback_authorization: dict[str, object] | None = None,
        created_at: str = "2026-08-23T19:00:00Z",
    ) -> dict[str, object]:
        pack = self.pack if pack is None else pack
        digest = hashlib.sha256(pack.read_bytes()).hexdigest()
        summary = installer.validate_content_pack(pack)
        return {
            "artifact": {
                "compressedSHA256": digest,
                "compressedSizeBytes": pack.stat().st_size,
                "compression": "none",
                "downloadURL": "https://content.wordbook.cool/releases/release.sqlite",
                "fileName": "release.sqlite",
                "uncompressedSHA256": digest,
                "uncompressedSizeBytes": pack.stat().st_size,
            },
            "contentVersion": summary["contentVersion"],
            "contracts": {
                "lessonContractVersion": summary["lessonContractVersion"],
                "normalizationVersion": summary["normalizationVersion"],
                "resolverContractVersion": summary["resolverContractVersion"],
                "reviewPolicyVersion": summary["reviewPolicyVersion"],
                "schemaVersion": summary["schemaVersion"],
                "usageSelectionPolicyVersion": summary[
                    "usageSelectionPolicyVersion"
                ],
                "validatorVersion": summary["validatorVersion"],
            },
            "counts": {
                "entries": summary["entries"],
                "explanations": summary["explanations"],
                "usages": summary["usages"],
            },
            "createdAt": created_at,
            "fixtureSHA256": summary["fixtureSHA256"],
            "locales": summary["locales"],
            "logicalContentDigest": summary["logicalContentDigest"],
            "manifestVersion": 1,
            "minimumAppBuild": 209,
            "releaseAttestationID": "rel_" + "3" * 64,
            "releaseSequence": release_sequence,
            "rollbackAuthorization": rollback_authorization,
            "signature": {
                "algorithm": "sshsig-ed25519",
                "fileName": "release-manifest.json.sig",
                "identity": self.identity,
                "keyID": self.key_id,
                "namespace": signed.SIGNATURE_NAMESPACE,
            },
            "targetManifestSHA256": "4" * 64,
        }

    def write_and_sign(self, manifest=None) -> Path:
        value = self.manifest() if manifest is None else manifest
        self.manifest_path.write_bytes(signed._canonical_json(value))
        signature_path = Path(str(self.manifest_path) + ".sig")
        signature_path.unlink(missing_ok=True)
        result = subprocess.run(
            [
                "ssh-keygen",
                "-Y",
                "sign",
                "-f",
                str(self.key),
                "-n",
                signed.SIGNATURE_NAMESPACE,
                str(self.manifest_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return signature_path

    def install_local_release(
        self,
        manifest: dict[str, object],
        *,
        pack: Path | None = None,
        rollback_key_ids: frozenset[str] = frozenset(),
    ) -> dict[str, object]:
        pack = self.pack if pack is None else pack
        signature = self.write_and_sign(manifest)
        real_install = installer.install_content_pack

        def install_from_fixture(**arguments):
            return real_install(
                destination=arguments["destination"],
                expected_sha256=arguments["expected_sha256"],
                source=pack,
                expected_size=arguments["expected_size"],
            )

        with mock.patch.object(
            signed.install_content_pack,
            "install_content_pack",
            side_effect=install_from_fixture,
        ):
            return signed.install_signed_release(
                destination=self.destination,
                allowed_signers=self.allowed_signers,
                current_app_build=209,
                manifest_source=self.manifest_path,
                signature_source=signature,
                rollback_key_ids=rollback_key_ids,
            )

    def test_verifies_signature_before_installing_exact_artifact(self) -> None:
        signature = self.write_and_sign()
        real_install = installer.install_content_pack

        def install_from_fixture(**arguments):
            self.assertEqual(
                self.manifest()["artifact"]["uncompressedSHA256"],
                arguments["expected_sha256"],
            )
            self.assertEqual(self.pack.stat().st_size, arguments["expected_size"])
            self.assertEqual(
                self.manifest()["artifact"]["downloadURL"], arguments["url"]
            )
            return real_install(
                destination=arguments["destination"],
                expected_sha256=arguments["expected_sha256"],
                source=self.pack,
                expected_size=arguments["expected_size"],
            )

        with mock.patch.object(
            signed.install_content_pack,
            "install_content_pack",
            side_effect=install_from_fixture,
        ) as install_call:
            manifest = signed.install_signed_release(
                destination=self.destination,
                allowed_signers=self.allowed_signers,
                current_app_build=209,
                manifest_source=self.manifest_path,
                signature_source=signature,
            )

        install_call.assert_called_once()
        self.assertEqual("test-content", manifest["contentVersion"])
        self.assertEqual(self.pack.read_bytes(), self.destination.read_bytes())
        installer.validate_content_pack(self.destination)
        receipt_path = signed._default_build_receipt_path(self.destination.resolve())
        receipt_payload = receipt_path.read_bytes()
        receipt = json.loads(receipt_payload)
        self.assertEqual(signed._canonical_json(receipt), receipt_payload)
        self.assertEqual(signed.BUILD_RECEIPT_KEYS, set(receipt))
        self.assertEqual(
            manifest["artifact"]["uncompressedSHA256"],
            receipt["artifactSHA256"],
        )
        self.assertEqual(manifest["counts"], receipt["counts"])
        self.assertEqual(manifest["contentVersion"], receipt["contentVersion"])
        self.assertEqual(manifest["minimumAppBuild"], receipt["minimumAppBuild"])

    def test_idempotent_install_recreates_missing_build_receipt(self) -> None:
        manifest = self.manifest()
        self.install_local_release(manifest)
        receipt_path = signed._default_build_receipt_path(self.destination.resolve())
        receipt_path.unlink()

        self.install_local_release(manifest)

        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["counts"], receipt["counts"])
        self.assertEqual(
            manifest["artifact"]["uncompressedSHA256"],
            receipt["artifactSHA256"],
        )

    def test_tampered_manifest_is_rejected_before_artifact_download(self) -> None:
        signature = self.write_and_sign()
        raw = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        raw["artifact"]["compressedSHA256"] = "9" * 64
        raw["artifact"]["uncompressedSHA256"] = "9" * 64
        self.manifest_path.write_bytes(signed._canonical_json(raw))

        with mock.patch.object(
            signed.install_content_pack, "install_content_pack"
        ) as install_call:
            with self.assertRaisesRegex(
                signed.SignedReleaseInstallError, "signature is not trusted"
            ):
                signed.install_signed_release(
                    destination=self.destination,
                    allowed_signers=self.allowed_signers,
                    current_app_build=209,
                    manifest_source=self.manifest_path,
                    signature_source=signature,
                )
        install_call.assert_not_called()
        self.assertFalse(self.destination.exists())

    def test_noncanonical_manifest_is_rejected_before_signature_check(self) -> None:
        value = self.manifest()
        self.manifest_path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        signature = self.root / "unused.sig"
        signature.write_text("not a signature", encoding="utf-8")

        with self.assertRaisesRegex(
            signed.SignedReleaseInstallError, "not byte-canonical"
        ):
            signed.install_signed_release(
                destination=self.destination,
                allowed_signers=self.allowed_signers,
                current_app_build=209,
                manifest_source=self.manifest_path,
                signature_source=signature,
            )

    def test_manifest_key_id_is_cryptographically_bound_to_signature(self) -> None:
        other_key = self.root / "other-release-key"
        generated = subprocess.run(
            [
                "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                "other-test-only", "-f", str(other_key),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, generated.returncode, generated.stderr)
        other_public = other_key.with_suffix(".pub").read_text(encoding="utf-8").strip()
        other_blob = base64.b64decode(other_public.split()[1], validate=True)
        other_key_id = "ssh-ed25519-sha256:" + hashlib.sha256(other_blob).hexdigest()
        with self.allowed_signers.open("a", encoding="utf-8") as stream:
            stream.write(f"{self.identity} {other_public}\n")
        manifest = self.manifest()
        manifest["signature"]["keyID"] = other_key_id
        signature = self.write_and_sign(manifest)

        with mock.patch.object(
            signed.install_content_pack, "install_content_pack"
        ) as install_call:
            with self.assertRaisesRegex(
                signed.SignedReleaseInstallError, "signature is not trusted"
            ):
                signed.install_signed_release(
                    destination=self.destination,
                    allowed_signers=self.allowed_signers,
                    current_app_build=209,
                    manifest_source=self.manifest_path,
                    signature_source=signature,
                )
        install_call.assert_not_called()

    def test_incompatible_build_contract_and_locale_stop_before_artifact(self) -> None:
        mutations = []
        too_new = self.manifest()
        too_new["minimumAppBuild"] = 210
        mutations.append((too_new, "requires a newer app build"))
        wrong_contract = self.manifest()
        wrong_contract["contracts"]["normalizationVersion"] = 2
        mutations.append((wrong_contract, "normalizationVersion is incompatible"))
        wrong_locale = self.manifest()
        wrong_locale["locales"] = ["fr"]
        mutations.append((wrong_locale, "release locales"))

        for manifest, expected_error in mutations:
            with self.subTest(expected_error=expected_error):
                signature = self.write_and_sign(manifest)
                with mock.patch.object(
                    signed.install_content_pack, "install_content_pack"
                ) as install_call:
                    with self.assertRaisesRegex(
                        signed.SignedReleaseInstallError, expected_error
                    ):
                        signed.install_signed_release(
                            destination=self.destination,
                            allowed_signers=self.allowed_signers,
                            current_app_build=209,
                            manifest_source=self.manifest_path,
                            signature_source=signature,
                        )
                install_call.assert_not_called()

    def test_signed_manifest_pack_mismatch_preserves_destination(self) -> None:
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"existing pack bytes")
        manifest = self.manifest()
        manifest["logicalContentDigest"] = "9" * 64

        with self.assertRaisesRegex(
            signed.SignedReleaseInstallError, "does not describe the verified SQLite pack"
        ):
            self.install_local_release(manifest)

        self.assertEqual(b"existing pack bytes", self.destination.read_bytes())
        self.assertFalse(signed._default_state_path(self.destination.resolve()).exists())

    def test_active_sidecar_without_state_fails_closed_before_artifact_install(self) -> None:
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"existing pack bytes")
        sidecar = Path(str(self.destination) + "-wal")
        sidecar.write_bytes(b"unsigned SQLite state")
        signature = self.write_and_sign()

        with mock.patch.object(
            signed.install_content_pack, "install_content_pack"
        ) as install_call:
            with self.assertRaisesRegex(
                signed.SignedReleaseInstallError,
                "not a standalone SQLite artifact",
            ):
                signed.install_signed_release(
                    destination=self.destination,
                    allowed_signers=self.allowed_signers,
                    current_app_build=209,
                    manifest_source=self.manifest_path,
                    signature_source=signature,
                )

        install_call.assert_not_called()
        self.assertEqual(b"existing pack bytes", self.destination.read_bytes())
        self.assertEqual(b"unsigned SQLite state", sidecar.read_bytes())
        self.assertFalse(signed._default_state_path(self.destination.resolve()).exists())

    def test_same_sequence_with_different_manifest_is_rejected(self) -> None:
        original = self.manifest()
        self.install_local_release(original)
        changed = self.manifest(created_at="2026-08-23T19:00:01Z")

        with self.assertRaisesRegex(
            signed.SignedReleaseInstallError, "different signed manifest"
        ):
            self.install_local_release(changed)

        self.assertEqual(self.pack.read_bytes(), self.destination.read_bytes())

    def test_authorized_rollback_retains_high_water_and_requires_new_sequence(self) -> None:
        self.install_local_release(self.manifest(release_sequence=42))
        rollback = self.manifest(
            release_sequence=41,
            rollback_authorization={
                "fromReleaseSequence": 42,
                "reasonCode": "known-bad-release",
            },
            created_at="2026-08-23T19:01:00Z",
        )

        with self.assertRaisesRegex(
            signed.SignedReleaseInstallError, "not authorized"
        ):
            self.install_local_release(rollback)

        self.install_local_release(
            rollback, rollback_key_ids=frozenset({self.key_id})
        )
        state_path = signed._default_state_path(self.destination.resolve())
        state = signed._load_state(state_path)
        assert state is not None
        self.assertEqual(41, state["releaseSequence"])
        self.assertEqual(42, state["highestAcceptedReleaseSequence"])

        with self.assertRaisesRegex(
            signed.SignedReleaseInstallError, "cannot be replayed"
        ):
            self.install_local_release(self.manifest(release_sequence=42))

        pack_43 = self.root / "release-43.sqlite"
        pack_tests.InstallContentPackTests.create_pack(
            self,
            pack_43,
            content_version="test-content-43",
            direct_explanation="A revised learner explanation for a test Entry.",
        )
        manifest_43 = self.manifest(
            pack=pack_43,
            release_sequence=43,
            created_at="2026-08-23T19:02:00Z",
        )
        self.install_local_release(manifest_43, pack=pack_43)
        state = signed._load_state(state_path)
        assert state is not None
        self.assertEqual(43, state["releaseSequence"])
        self.assertEqual(43, state["highestAcceptedReleaseSequence"])

    def test_state_binding_rejects_an_unrelated_active_pack(self) -> None:
        self.install_local_release(self.manifest(release_sequence=42))
        self.destination.write_bytes(self.destination.read_bytes() + b"corruption")
        manifest_43 = self.manifest(
            release_sequence=43, created_at="2026-08-23T19:02:00Z"
        )
        signature = self.write_and_sign(manifest_43)

        with mock.patch.object(
            signed.install_content_pack, "install_content_pack"
        ) as install_call:
            with self.assertRaisesRegex(
                signed.SignedReleaseInstallError, "does not match the installed release state"
            ):
                signed.install_signed_release(
                    destination=self.destination,
                    allowed_signers=self.allowed_signers,
                    current_app_build=209,
                    manifest_source=self.manifest_path,
                    signature_source=signature,
                )
        install_call.assert_not_called()

    def test_upgrade_preserves_previous_good_and_bad_candidate_cannot_activate(self) -> None:
        original_bytes = self.pack.read_bytes()
        self.install_local_release(self.manifest(release_sequence=42))
        pack_43 = self.root / "release-43.sqlite"
        pack_tests.InstallContentPackTests.create_pack(
            self,
            pack_43,
            content_version="test-content-43",
            direct_explanation="A revised learner explanation for a test Entry.",
        )
        manifest_43 = self.manifest(
            pack=pack_43,
            release_sequence=43,
            created_at="2026-08-23T19:02:00Z",
        )
        self.install_local_release(manifest_43, pack=pack_43)
        previous = signed._default_previous_good_path(self.destination.resolve())
        self.assertEqual(original_bytes, previous.read_bytes())
        self.assertEqual(pack_43.read_bytes(), self.destination.read_bytes())

        bad_44 = self.manifest(
            pack=pack_43,
            release_sequence=44,
            created_at="2026-08-23T19:03:00Z",
        )
        bad_44["logicalContentDigest"] = "9" * 64
        with self.assertRaisesRegex(
            signed.SignedReleaseInstallError, "does not describe the verified SQLite pack"
        ):
            self.install_local_release(bad_44, pack=pack_43)
        self.assertEqual(pack_43.read_bytes(), self.destination.read_bytes())

    def test_pending_receipt_recovers_pack_rename_before_state_write(self) -> None:
        self.install_local_release(self.manifest(release_sequence=42))
        pack_43 = self.root / "release-43.sqlite"
        pack_tests.InstallContentPackTests.create_pack(
            self,
            pack_43,
            content_version="test-content-43",
            direct_explanation="A revised learner explanation for a test Entry.",
        )
        manifest_43 = self.manifest(
            pack=pack_43,
            release_sequence=43,
            created_at="2026-08-23T19:02:00Z",
        )
        signature = self.write_and_sign(manifest_43)
        real_install = installer.install_content_pack
        real_write = signed._write_atomic
        state_path = signed._default_state_path(self.destination.resolve())
        pending_path = signed._default_pending_path(state_path)

        def install_from_fixture(**arguments):
            return real_install(
                destination=arguments["destination"],
                expected_sha256=arguments["expected_sha256"],
                source=pack_43,
                expected_size=arguments["expected_size"],
            )

        def fail_new_state(path, payload, *, mode):
            if Path(path) == state_path:
                decoded = json.loads(payload)
                if decoded.get("releaseSequence") == 43:
                    raise signed.SignedReleaseInstallError("simulated state write failure")
            return real_write(Path(path), payload, mode=mode)

        with mock.patch.object(
            signed.install_content_pack,
            "install_content_pack",
            side_effect=install_from_fixture,
        ), mock.patch.object(signed, "_write_atomic", side_effect=fail_new_state):
            with self.assertRaisesRegex(
                signed.SignedReleaseInstallError, "simulated state write failure"
            ):
                signed.install_signed_release(
                    destination=self.destination,
                    allowed_signers=self.allowed_signers,
                    current_app_build=209,
                    manifest_source=self.manifest_path,
                    signature_source=signature,
                )

        self.assertEqual(pack_43.read_bytes(), self.destination.read_bytes())
        self.assertTrue(pending_path.is_file())
        stale_state = signed._load_state(state_path)
        assert stale_state is not None
        self.assertEqual(42, stale_state["releaseSequence"])

        self.install_local_release(manifest_43, pack=pack_43)
        recovered = signed._load_state(state_path)
        assert recovered is not None
        self.assertEqual(43, recovered["releaseSequence"])
        self.assertFalse(pending_path.exists())

    def test_previous_good_path_may_use_a_new_parent_directory(self) -> None:
        previous = self.root / "recovery/nested/previous.sqlite"

        signed._preserve_previous_good(self.pack, previous)

        self.assertEqual(self.pack.read_bytes(), previous.read_bytes())


if __name__ == "__main__":
    unittest.main()
