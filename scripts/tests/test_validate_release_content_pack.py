#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest


SCRIPTS_DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import install_content_pack as installer  # noqa: E402
import test_install_content_pack as pack_tests  # noqa: E402
import validate_release_content_pack as validator  # noqa: E402


class ValidateReleaseContentPackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.pack = self.root / "wordbook-content.sqlite"
        self.receipt = self.root / ".wordbook-content-build-receipt.json"
        pack_tests.InstallContentPackTests.create_pack(self, self.pack)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def receipt_value(self) -> dict[str, object]:
        summary = installer.validate_content_pack(self.pack)
        return {
            "artifactSHA256": hashlib.sha256(self.pack.read_bytes()).hexdigest(),
            "artifactSizeBytes": self.pack.stat().st_size,
            "buildReceiptVersion": 1,
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
            "fixtureSHA256": summary["fixtureSHA256"],
            "logicalContentDigest": summary["logicalContentDigest"],
            "manifestSHA256": "2" * 64,
            "minimumAppBuild": 209,
            "releaseSequence": 42,
            "signatureKeyID": "ssh-ed25519-sha256:" + "3" * 64,
        }

    def write_receipt(self, value: dict[str, object] | None = None) -> None:
        self.receipt.write_bytes(
            validator._canonical_json(self.receipt_value() if value is None else value)
        )

    def validate(self) -> dict[str, object]:
        return validator.validate_content_pack(
            pack_path=self.pack,
            expectations=validator.load_build_receipt(self.receipt),
            current_app_build=209,
        )

    def test_valid_signed_release_receipt_binds_exact_read_only_pack(self) -> None:
        self.write_receipt()
        before = hashlib.sha256(self.pack.read_bytes()).hexdigest()

        summary = self.validate()

        self.assertEqual("test-content", summary["contentVersion"])
        self.assertEqual(before, hashlib.sha256(self.pack.read_bytes()).hexdigest())
        self.assertFalse(Path(str(self.pack) + "-wal").exists())
        self.assertFalse(Path(str(self.pack) + "-shm").exists())

    def test_missing_receipt_and_incomplete_environment_fail_closed(self) -> None:
        with self.assertRaisesRegex(
            validator.ReleaseContentValidationError,
            "explicit release expectations are incomplete",
        ):
            validator.main(
                ["--pack", str(self.pack), "--app-build", "209"],
                environment={},
            )

    def test_explicit_environment_can_supply_exact_release_expectations(self) -> None:
        summary = installer.validate_content_pack(self.pack)
        environment = {
            validator.EXPECTED_SHA256_ENV: hashlib.sha256(
                self.pack.read_bytes()
            ).hexdigest(),
            validator.EXPECTED_CONTENT_VERSION_ENV: summary["contentVersion"],
            validator.EXPECTED_ENTRY_COUNT_ENV: str(summary["entries"]),
            validator.EXPECTED_USAGE_COUNT_ENV: str(summary["usages"]),
            validator.EXPECTED_EXPLANATION_COUNT_ENV: str(summary["explanations"]),
            validator.EXPECTED_MINIMUM_APP_BUILD_ENV: "209",
        }

        result = validator.main(
            ["--pack", str(self.pack), "--app-build", "209"],
            environment=environment,
        )

        self.assertEqual(0, result)

    def test_counts_below_signed_manifest_expectation_are_rejected(self) -> None:
        receipt = self.receipt_value()
        receipt["counts"] = {"entries": 2, "explanations": 2, "usages": 2}
        self.write_receipt(receipt)

        with self.assertRaisesRegex(
            validator.ReleaseContentValidationError,
            "counts are below the authenticated release expectation",
        ):
            self.validate()

    def test_artifact_digest_must_match_receipt(self) -> None:
        receipt = self.receipt_value()
        receipt["artifactSHA256"] = "9" * 64
        self.write_receipt(receipt)

        with self.assertRaisesRegex(
            validator.ReleaseContentValidationError,
            "SHA-256 does not match",
        ):
            self.validate()

    def test_schema_one_pack_is_rejected_even_when_receipt_matches_bytes(self) -> None:
        receipt = self.receipt_value()
        with sqlite3.connect(self.pack) as connection:
            connection.execute("PRAGMA user_version = 1")
        receipt["artifactSHA256"] = hashlib.sha256(self.pack.read_bytes()).hexdigest()
        receipt["artifactSizeBytes"] = self.pack.stat().st_size
        self.write_receipt(receipt)

        with self.assertRaisesRegex(
            validator.ReleaseContentValidationError,
            "Release requires schema 2",
        ):
            self.validate()

    def test_foreign_key_damage_is_rejected(self) -> None:
        receipt = self.receipt_value()
        with sqlite3.connect(self.pack) as connection:
            connection.execute("PRAGMA foreign_keys = OFF")
            connection.execute("DELETE FROM word_entry")
        receipt["artifactSHA256"] = hashlib.sha256(self.pack.read_bytes()).hexdigest()
        receipt["artifactSizeBytes"] = self.pack.stat().st_size
        self.write_receipt(receipt)

        with self.assertRaisesRegex(
            validator.ReleaseContentValidationError,
            "foreign_key_check",
        ):
            self.validate()

    def test_known_fixture_content_version_is_always_rejected(self) -> None:
        self.pack.unlink()
        pack_tests.InstallContentPackTests.create_pack(
            self,
            self.pack,
            content_version=validator.KNOWN_FIXTURE_CONTENT_VERSION,
        )
        self.write_receipt()

        with self.assertRaisesRegex(
            validator.ReleaseContentValidationError,
            "known fixture content version",
        ):
            self.validate()

    def test_known_fixture_artifact_digest_is_always_rejected(self) -> None:
        with self.assertRaisesRegex(
            validator.ReleaseContentValidationError,
            "known 7-Entry fixture",
        ):
            validator._reject_known_fixture(
                artifact_sha256=validator.KNOWN_FIXTURE_ARTIFACT_SHA256,
                content_version="production",
                fixture_sha256="1" * 64,
                counts={"entries": 10, "usages": 10, "explanations": 10},
            )


if __name__ == "__main__":
    unittest.main()
