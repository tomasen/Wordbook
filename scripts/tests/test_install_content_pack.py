#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS_DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS_DIRECTORY))

import install_content_pack as installer  # noqa: E402


class InstallContentPackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.source = self.root / "release.sqlite"
        self.destination = self.root / "repository/Shared/wordbook-content.sqlite"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def create_pack(
        self,
        path: Path,
        *,
        application_id: int = installer.APPLICATION_ID,
        user_version: int = installer.SCHEMA_VERSION,
        omitted_table: str = "",
        content_version: str = "test-content",
        base_content_version: str | None = None,
        direct_explanation: str = "A small valid learner explanation for a test Entry.",
        weak_schema: bool = False,
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(path)
        try:
            if not weak_schema:
                connection.executescript(
                    installer.SCHEMA_PATH.read_text(encoding="utf-8")
                )
                if omitted_table:
                    connection.execute(f'DROP TABLE "{omitted_table}"')
            connection.execute(f"PRAGMA application_id = {application_id}")
            connection.execute(f"PRAGMA user_version = {user_version}")
            definitions = {
                "metadata": "CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
                "word_entry": """
                    CREATE TABLE word_entry(
                        entry_id TEXT PRIMARY KEY, language_tag TEXT,
                        normalized_form TEXT, display_form TEXT,
                        normalization_version INTEGER, entry_revision INTEGER,
                        entry_rank INTEGER
                    )
                """,
                "entry_usage": """
                    CREATE TABLE entry_usage(
                        entry_usage_id TEXT PRIMARY KEY, entry_id TEXT,
                        language_tag TEXT, normalized_form TEXT,
                        part_of_speech_label TEXT, learner_label TEXT,
                        pronunciation_json TEXT, form_relation_label TEXT,
                        context_vector_format_version INTEGER, context_vector BLOB,
                        display_order INTEGER, commonness_rank INTEGER,
                        is_core INTEGER
                    )
                """,
                "released_lesson_variant": """
                    CREATE TABLE released_lesson_variant(
                        explanation_id TEXT PRIMARY KEY, entry_id TEXT,
                        entry_usage_id TEXT, locale TEXT, schema_version INTEGER,
                        lesson_contract_version INTEGER, validator_version INTEGER,
                        review_policy_version INTEGER, content_revision INTEGER,
                        content_hash TEXT, direct_explanation TEXT, example TEXT,
                        synonyms_json TEXT, memory_cue_json TEXT, trust_state TEXT
                    )
                """,
                "entry_default": """
                    CREATE TABLE entry_default(
                        entry_id TEXT, entry_usage_id TEXT, locale TEXT,
                        explanation_id TEXT
                    )
                """,
                "entry_coverage": """
                    CREATE TABLE entry_coverage(
                        entry_id TEXT, locale TEXT, coverage_revision INTEGER,
                        expected_usage_count INTEGER, expected_core_count INTEGER,
                        available_usage_count INTEGER, has_more_usages INTEGER,
                        coverage_state TEXT, content_version TEXT,
                        usage_selection_policy_version INTEGER,
                        lesson_contract_version INTEGER, validator_version INTEGER,
                        review_policy_version INTEGER
                    )
                """,
                "entry_migration": """
                    CREATE TABLE entry_migration(
                        release_sequence INTEGER, old_entry_id TEXT,
                        old_language_tag TEXT, old_normalized_form TEXT,
                        new_entry_id TEXT, reason_code TEXT
                    )
                """,
                "entry_usage_disposition": """
                    CREATE TABLE entry_usage_disposition(
                        release_sequence INTEGER, old_entry_id TEXT,
                        old_entry_usage_id TEXT, disposition TEXT,
                        new_entry_id TEXT, new_entry_usage_id TEXT,
                        migration_release_sequence INTEGER, reason_code TEXT
                    )
                """,
                "explanation_disposition": """
                    CREATE TABLE explanation_disposition(
                        release_sequence INTEGER, entry_id TEXT,
                        entry_usage_id TEXT, old_explanation_id TEXT,
                        disposition TEXT, replacement_explanation_id TEXT,
                        locale TEXT, reason_code TEXT
                    )
                """,
            }
            if weak_schema:
                for table_name in sorted(installer.REQUIRED_TABLES):
                    if table_name != omitted_table:
                        connection.execute(definitions[table_name])
            if not omitted_table:
                envelope = {
                    "directExplanation": direct_explanation,
                    "entryID": "ent_test",
                    "entryUsageID": "eus_test",
                    "example": "The test entry appears in this sentence.",
                    "language": "en",
                    "lessonContractVersion": 2,
                    "locale": "en",
                    "memoryCue": None,
                    "normalizedForm": "test",
                    "schemaVersion": 2,
                    "synonyms": [],
                }
                canonical = json.dumps(
                    envelope, ensure_ascii=False, separators=(",", ":"), sort_keys=True
                ).encode("utf-8")
                content_hash = hashlib.sha256(canonical).hexdigest()
                explanation_id = f"exp_{content_hash}"
                connection.execute(
                    "INSERT INTO word_entry VALUES (?, 'en', 'test', 'test', 1, 1, 1)",
                    ("ent_test",),
                )
                connection.execute(
                    """
                    INSERT INTO entry_usage VALUES (
                        'eus_test', 'ent_test', 'en', 'test', 'noun', NULL,
                        '[{"ipa":"tɛst","locale":"en-US"}]', NULL,
                        NULL, NULL, 0, 1, 1
                    )
                    """
                )
                connection.execute(
                    """
                    INSERT INTO released_lesson_variant VALUES (
                        ?, 'ent_test', 'eus_test', 'en', 2, 2, 2, 5, 1,
                        ?, ?, ?, '[]', NULL, 'releaseReviewed'
                    )
                    """,
                    (
                        explanation_id,
                        content_hash,
                        envelope["directExplanation"],
                        envelope["example"],
                    ),
                )
                connection.execute(
                    "INSERT INTO entry_default VALUES ('ent_test', 'eus_test', 'en', ?)",
                    (explanation_id,),
                )
                connection.execute(
                    """
                    INSERT INTO entry_coverage VALUES (
                        'ent_test', 'en', 1, 1, 1, 1, 0,
                        'releaseReviewedComplete', ?, 1, 2, 2, 5
                    )
                    """,
                    (content_version,),
                )
                logical_digest = installer._logical_content_digest(connection)
                metadata = {
                    "application_id": str(installer.APPLICATION_ID),
                    "base_content_version": (
                        content_version
                        if base_content_version is None
                        else base_content_version
                    ),
                    "content_version": content_version,
                    "database_kind": installer.DATABASE_KIND,
                    "entry_count": "1",
                    "explanation_count": "1",
                    "fixture_sha256": "1" * 64,
                    "lesson_contract_version": "2",
                    "logical_content_digest": logical_digest,
                    "normalization_version": "1",
                    "resolver_contract_version": "1",
                    "review_policy_version": "5",
                    "schema_version": str(installer.SCHEMA_VERSION),
                    "usage_count": "1",
                    "usage_selection_policy_version": "1",
                    "validator_version": "2",
                }
                self.assertEqual(installer.METADATA_KEYS, set(metadata))
                connection.executemany(
                    "INSERT INTO metadata(key, value) VALUES (?, ?)",
                    sorted(metadata.items()),
                )
            connection.commit()
        finally:
            connection.close()

    @staticmethod
    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def install(self, source: Path, digest: str) -> str:
        return installer.install_content_pack(
            destination=self.destination,
            expected_sha256=digest,
            source=source,
        )

    def test_valid_pack_is_installed_and_reported_digest_matches(self) -> None:
        self.create_pack(self.source)
        expected_digest = self.digest(self.source)

        installed_digest = self.install(self.source, expected_digest.upper())

        self.assertEqual(installed_digest, expected_digest)
        self.assertEqual(self.destination.read_bytes(), self.source.read_bytes())
        installer.validate_content_pack(self.destination)
        self.assertEqual(list(self.destination.parent.glob(".wordbook-content.sqlite.*.tmp")), [])

    def test_catalog_base_content_version_must_equal_content_version(self) -> None:
        self.create_pack(
            self.source,
            content_version="catalog-v2",
            base_content_version="catalog-v1",
        )

        with self.assertRaisesRegex(
            installer.ContentPackInstallError,
            "base_content_version must equal content_version",
        ):
            installer.validate_content_pack(self.source)

    def test_validation_rejects_sqlite_sidecar_that_is_not_in_signed_bytes(self) -> None:
        self.create_pack(self.source)
        sidecar = Path(str(self.source) + "-wal")
        sidecar.write_bytes(b"not part of the signed standalone artifact")

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "not a standalone SQLite artifact"
        ):
            installer.validate_content_pack(self.source)

        self.assertTrue(sidecar.is_file())

    def test_destination_sidecar_fails_closed_without_touching_existing_files(self) -> None:
        self.create_pack(self.source)
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"existing pack bytes")
        sidecar = Path(str(self.destination) + "-journal")
        sidecar.write_bytes(b"existing journal bytes")

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "not a standalone SQLite artifact"
        ):
            self.install(self.source, self.digest(self.source))

        self.assertEqual(b"existing pack bytes", self.destination.read_bytes())
        self.assertEqual(b"existing journal bytes", sidecar.read_bytes())
        self.assertEqual(
            [], list(self.destination.parent.glob(".wordbook-content.sqlite.*.tmp"))
        )

    def test_tampered_pack_is_rejected_without_replacing_existing_pack(self) -> None:
        self.create_pack(self.source)
        pinned_digest = self.digest(self.source)
        self.source.write_bytes(self.source.read_bytes() + b"tampered")
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"existing known-good pack")

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "SHA-256 mismatch"
        ):
            self.install(self.source, pinned_digest)

        self.assertEqual(self.destination.read_bytes(), b"existing known-good pack")
        self.assertEqual(list(self.destination.parent.glob(".wordbook-content.sqlite.*.tmp")), [])

    def test_signed_manifest_size_mismatch_is_rejected_before_install(self) -> None:
        self.create_pack(self.source)
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"existing known-good pack")

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "byte size does not match"
        ):
            installer.install_content_pack(
                destination=self.destination,
                expected_sha256=self.digest(self.source),
                source=self.source,
                expected_size=self.source.stat().st_size + 1,
            )

        self.assertEqual(self.destination.read_bytes(), b"existing known-good pack")

    def test_wrong_schema_is_rejected_even_when_digest_is_correct(self) -> None:
        self.create_pack(self.source, user_version=installer.SCHEMA_VERSION + 1)
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"existing known-good pack")

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "unsupported schema version"
        ):
            self.install(self.source, self.digest(self.source))

        self.assertEqual(self.destination.read_bytes(), b"existing known-good pack")

    def test_lesson_hash_mismatch_is_rejected(self) -> None:
        self.create_pack(self.source)
        connection = sqlite3.connect(self.source)
        try:
            connection.execute(
                "UPDATE released_lesson_variant SET direct_explanation = 'tampered prose'"
            )
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "immutable content hash"
        ):
            self.install(self.source, self.digest(self.source))

    def test_incomplete_entry_coverage_is_rejected(self) -> None:
        self.create_pack(self.source)
        connection = sqlite3.connect(self.source)
        try:
            connection.execute("PRAGMA ignore_check_constraints = ON")
            connection.execute(
                "UPDATE entry_coverage SET expected_usage_count = 2, available_usage_count = 2"
            )
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "incomplete Entry coverage"
        ):
            self.install(self.source, self.digest(self.source))

    def test_atomic_replace_failure_preserves_old_pack_and_cleans_staging_file(self) -> None:
        self.create_pack(self.source)
        self.destination.parent.mkdir(parents=True)
        self.destination.write_bytes(b"previous pack")
        observed_temporary_path = None

        def fail_replace(source: Path, destination: Path) -> None:
            nonlocal observed_temporary_path
            observed_temporary_path = Path(source)
            self.assertEqual(Path(destination), self.destination)
            self.assertEqual(Path(source).parent, self.destination.parent)
            installer.validate_content_pack(Path(source))
            raise OSError("simulated atomic replacement failure")

        with mock.patch.object(installer.os, "replace", side_effect=fail_replace):
            with self.assertRaisesRegex(
                installer.ContentPackInstallError, "atomically install"
            ):
                self.install(self.source, self.digest(self.source))

        self.assertIsNotNone(observed_temporary_path)
        assert observed_temporary_path is not None
        self.assertFalse(observed_temporary_path.exists())
        self.assertEqual(self.destination.read_bytes(), b"previous pack")

    def test_missing_source_has_actionable_error(self) -> None:
        missing = self.root / "missing.sqlite"
        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "Generate the pack first"
        ):
            self.install(missing, "0" * 64)

    def test_database_with_missing_essential_table_is_rejected(self) -> None:
        self.create_pack(self.source, omitted_table="entry_default")

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "schema tables do not match"
        ):
            self.install(self.source, self.digest(self.source))

    def test_column_only_lookalike_schema_is_rejected(self) -> None:
        self.create_pack(self.source, weak_schema=True)

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "schema structure does not match"
        ):
            self.install(self.source, self.digest(self.source))

    def test_metadata_blob_is_rejected_as_not_runtime_readable_text(self) -> None:
        self.create_pack(self.source)
        connection = sqlite3.connect(self.source)
        try:
            connection.execute(
                "UPDATE metadata SET value = CAST(value AS BLOB) "
                "WHERE key = 'content_version'"
            )
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "must be SQLite TEXT"
        ):
            self.install(self.source, self.digest(self.source))

    def test_pronunciation_shape_rejected_before_runtime(self) -> None:
        self.create_pack(self.source)
        connection = sqlite3.connect(self.source)
        try:
            connection.execute(
                "UPDATE entry_usage SET pronunciation_json = '[{\"wrong\":true}]'"
            )
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "pronunciation 0 has invalid fields"
        ):
            self.install(self.source, self.digest(self.source))

    def test_invalid_core_and_rank_values_are_rejected(self) -> None:
        self.create_pack(self.source)
        connection = sqlite3.connect(self.source)
        try:
            connection.execute("PRAGMA ignore_check_constraints = ON")
            connection.execute(
                "UPDATE entry_coverage SET expected_core_count = 0, has_more_usages = 1"
            )
            connection.execute(
                "UPDATE entry_usage SET commonness_rank = -1, is_core = 0"
            )
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "coverage bounds"
        ):
            self.install(self.source, self.digest(self.source))

    def test_invalid_content_revision_is_rejected(self) -> None:
        self.create_pack(self.source)
        connection = sqlite3.connect(self.source)
        try:
            connection.execute("PRAGMA ignore_check_constraints = ON")
            connection.execute(
                "UPDATE released_lesson_variant SET content_revision = 0"
            )
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "identity or revision"
        ):
            self.install(self.source, self.digest(self.source))

    def test_broken_default_foreign_key_is_rejected(self) -> None:
        self.create_pack(self.source)
        connection = sqlite3.connect(self.source)
        try:
            connection.execute(
                "UPDATE entry_default SET explanation_id = 'exp_missing'"
            )
            connection.commit()
        finally:
            connection.close()

        with self.assertRaisesRegex(
            installer.ContentPackInstallError, "foreign_key_check"
        ):
            self.install(self.source, self.digest(self.source))

    def test_reserved_disposition_tables_must_remain_empty_for_v1_resolver(self) -> None:
        inserts = {
            "entry_migration": (
                "INSERT INTO entry_migration VALUES "
                "(1, 'ent_old', 'en', 'old', 'ent_test', 'identity-merged')"
            ),
            "entry_usage_disposition": (
                "INSERT INTO entry_usage_disposition VALUES "
                "(1, 'ent_test', 'eus_old', 'redirected', "
                "'ent_test', 'eus_test', NULL, 'usage-merged')"
            ),
            "explanation_disposition": (
                "INSERT INTO explanation_disposition "
                "SELECT 1, entry_id, entry_usage_id, 'exp_old', 'replaced', "
                "explanation_id, locale, 'lesson-replaced' "
                "FROM released_lesson_variant"
            ),
        }
        for table, statement in inserts.items():
            with self.subTest(table=table):
                candidate = self.root / f"{table}.sqlite"
                self.create_pack(candidate)
                connection = sqlite3.connect(candidate)
                try:
                    connection.execute(statement)
                    connection.commit()
                finally:
                    connection.close()

                with self.assertRaisesRegex(
                    installer.ContentPackInstallError,
                    "resolver contract cannot apply",
                ):
                    installer.validate_content_pack(candidate)

    def test_environment_defaults_select_source_and_pinned_digest(self) -> None:
        self.create_pack(self.source)
        environment = {
            installer.SOURCE_ENV: str(self.source),
            installer.SHA256_ENV: self.digest(self.source),
        }

        source, url = installer.resolve_input(
            source_argument=None,
            url_argument=None,
            environment=environment,
        )

        self.assertEqual(source, self.source)
        self.assertIsNone(url)
        self.assertEqual(
            installer.normalize_sha256(environment[installer.SHA256_ENV]),
            self.digest(self.source),
        )


if __name__ == "__main__":
    unittest.main()
