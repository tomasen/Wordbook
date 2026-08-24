#!/usr/bin/env python3
"""Install Wordbook's pinned explanation database outside Git.

The pack can come from a local file or an HTTPS URL. Its SHA-256 must be
provided explicitly, so a mutable release URL can never silently change the
database used by a developer build.

Environment defaults:
    WORDBOOK_CONTENT_SOURCE
    WORDBOOK_CONTENT_URL
    WORDBOOK_CONTENT_SHA256
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import tempfile
from typing import Mapping, Optional, Sequence, Tuple
import urllib.error
import urllib.parse
import urllib.request

from normalization_v1 import normalize_form as normalize_form_v1


APPLICATION_ID = 1_463_960_400
SCHEMA_VERSION = 2
LESSON_CONTRACT_VERSION = 2
NORMALIZATION_VERSION = 1
RESOLVER_CONTRACT_VERSION = 1
MINIMUM_VALIDATOR_VERSION = 2
MINIMUM_REVIEW_POLICY_VERSION = 5
USAGE_SELECTION_POLICY_VERSION = 1
SUPPORTED_CONTENT_LOCALES = ("en",)
CHUNK_SIZE = 4 * 1024 * 1024
USER_AGENT = "Wordbook-content-pack-installer/1"
DATABASE_KIND = "entry_content_pack"
EXPECTED_TABLE_COLUMNS = {
    "metadata": ("key", "value"),
    "word_entry": (
        "entry_id", "language_tag", "normalized_form", "display_form",
        "normalization_version", "entry_revision", "entry_rank",
    ),
    "entry_usage": (
        "entry_usage_id", "entry_id", "language_tag", "normalized_form",
        "part_of_speech_label", "learner_label", "pronunciation_json",
        "form_relation_label", "context_vector_format_version", "context_vector",
        "display_order", "commonness_rank", "is_core",
    ),
    "released_lesson_variant": (
        "explanation_id", "entry_id", "entry_usage_id", "locale",
        "schema_version", "lesson_contract_version", "validator_version",
        "review_policy_version", "content_revision", "content_hash",
        "direct_explanation", "example", "synonyms_json", "memory_cue_json",
        "trust_state",
    ),
    "entry_default": ("entry_id", "entry_usage_id", "locale", "explanation_id"),
    "entry_coverage": (
        "entry_id", "locale", "coverage_revision", "expected_usage_count",
        "expected_core_count", "available_usage_count", "has_more_usages",
        "coverage_state", "content_version", "usage_selection_policy_version",
        "lesson_contract_version", "validator_version", "review_policy_version",
    ),
    "entry_migration": (
        "release_sequence", "old_entry_id", "old_language_tag",
        "old_normalized_form", "new_entry_id", "reason_code",
    ),
    "entry_usage_disposition": (
        "release_sequence", "old_entry_id", "old_entry_usage_id", "disposition",
        "new_entry_id", "new_entry_usage_id", "migration_release_sequence",
        "reason_code",
    ),
    "explanation_disposition": (
        "release_sequence", "entry_id", "entry_usage_id", "old_explanation_id",
        "disposition", "replacement_explanation_id", "locale", "reason_code",
    ),
}
REQUIRED_TABLES = frozenset(EXPECTED_TABLE_COLUMNS)
METADATA_KEYS = frozenset(
    {
        "application_id", "base_content_version", "content_version",
        "database_kind", "entry_count", "explanation_count", "fixture_sha256",
        "lesson_contract_version", "logical_content_digest",
        "normalization_version", "resolver_contract_version",
        "review_policy_version", "schema_version", "usage_count",
        "usage_selection_policy_version", "validator_version",
    }
)
FORBIDDEN_PUBLIC_IDENTIFIERS = (
    "lexeme",
    "sense_id",
    "source_sense",
    "lemma",
    "morphology",
    "gloss",
    "teaching_brief",
    "evidence_hash",
    "reviewer_identity",
    "model_trace",
    "provenance",
    "source_gloss",
    "source_example",
    "generator_prompt",
    "review_record",
)
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
PUBLIC_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,191}$")
MEMORY_TECHNIQUES = frozenset({"wordParts", "contrast", "image", "sound", "spelling"})

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
CONTENT_PACK_PATH = REPOSITORY_ROOT / "Shared/wordbook-content.sqlite"
SCHEMA_PATH = Path(__file__).resolve().with_name("entry_content_schema.sql")

SOURCE_ENV = "WORDBOOK_CONTENT_SOURCE"
URL_ENV = "WORDBOOK_CONTENT_URL"
SHA256_ENV = "WORDBOOK_CONTENT_SHA256"
SHA256_PATTERN = re.compile(r"[0-9a-fA-F]{64}\Z")


class ContentPackInstallError(RuntimeError):
    """A developer-actionable content-pack installation failure."""


def reject_sqlite_sidecars(path: Path) -> None:
    present = [
        candidate
        for candidate in (
            Path(str(path) + "-wal"),
            Path(str(path) + "-shm"),
            Path(str(path) + "-journal"),
        )
        if candidate.exists() or candidate.is_symlink()
    ]
    if present:
        raise ContentPackInstallError(
            "Content pack is not a standalone SQLite artifact; remove or checkpoint "
            "its sidecars before release: " + ", ".join(str(value) for value in present)
        )


def fsync_directory(path: Path) -> None:
    """Persist a completed rename in its containing directory."""

    try:
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        raise ContentPackInstallError(
            f"Could not persist the content-pack directory {path}: {error}"
        ) from error


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(CHUNK_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def normalize_sha256(value: Optional[str]) -> str:
    if value is None or not value.strip():
        raise ContentPackInstallError(
            "No SHA-256 was provided. Pass --sha256 DIGEST or set "
            f"{SHA256_ENV} to the digest published with the content pack."
        )
    digest = value.strip().lower()
    if SHA256_PATTERN.fullmatch(digest) is None:
        raise ContentPackInstallError(
            "The pinned SHA-256 must contain exactly 64 hexadecimal characters."
        )
    return digest


def validate_https_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme.lower() != "https" or not parsed.netloc:
        raise ContentPackInstallError(
            "The content-pack URL must be an absolute HTTPS URL; HTTP and local-file URLs "
            "are not accepted."
        )
    if parsed.username is not None or parsed.password is not None:
        raise ContentPackInstallError("The content-pack URL must not contain credentials.")
    return value


def resolve_input(
    *,
    source_argument: Optional[str],
    url_argument: Optional[str],
    environment: Mapping[str, str],
) -> Tuple[Optional[Path], Optional[str]]:
    # An explicit CLI location overrides environment defaults as a unit. This
    # avoids an explicit --source conflicting with a stale URL in the shell.
    if source_argument is not None or url_argument is not None:
        source_value = source_argument
        url_value = url_argument
    else:
        source_value = environment.get(SOURCE_ENV) or None
        url_value = environment.get(URL_ENV) or None

    if source_value and url_value:
        raise ContentPackInstallError(
            "Both a local source and a URL are configured. Choose exactly one of --source or "
            f"--url (or unset one of {SOURCE_ENV} and {URL_ENV})."
        )
    if source_value:
        return Path(source_value).expanduser(), None
    if url_value:
        return None, validate_https_url(url_value)
    raise ContentPackInstallError(
        "No content pack is configured. Generate or download a release, then pass "
        f"--source PATH or --url HTTPS_URL (or set {SOURCE_ENV} or {URL_ENV})."
    )


def copy_local_source(
    source: Path, destination: Path, *, expected_size: Optional[int] = None
) -> None:
    reject_sqlite_sidecars(source)
    if not source.exists():
        raise ContentPackInstallError(
            f"Content-pack source does not exist: {source}. Generate the pack first or pass "
            "the path to an existing release artifact."
        )
    if not source.is_file():
        raise ContentPackInstallError(f"Content-pack source is not a regular file: {source}")
    if expected_size is not None and source.stat().st_size != expected_size:
        raise ContentPackInstallError(
            "Content-pack byte size does not match the signed release manifest: "
            f"expected {expected_size}, found {source.stat().st_size}."
        )
    try:
        with source.open("rb") as input_stream, destination.open("wb") as output_stream:
            shutil.copyfileobj(input_stream, output_stream, length=CHUNK_SIZE)
            output_stream.flush()
            os.fsync(output_stream.fileno())
    except OSError as error:
        raise ContentPackInstallError(
            f"Could not copy content pack from {source}: {error}"
        ) from error


def download_https(
    url: str, destination: Path, *, expected_size: Optional[int] = None
) -> None:
    request = urllib.request.Request(
        validate_https_url(url),
        headers={"Accept-Encoding": "identity", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            final_url = response.geturl()
            validate_https_url(final_url)
            declared_size = response.headers.get("Content-Length")
            if expected_size is not None and declared_size is not None:
                try:
                    parsed_size = int(declared_size)
                except ValueError as error:
                    raise ContentPackInstallError(
                        "Content-pack server returned an invalid Content-Length."
                    ) from error
                if parsed_size != expected_size:
                    raise ContentPackInstallError(
                        "Content-pack Content-Length does not match the signed release "
                        f"manifest: expected {expected_size}, found {parsed_size}."
                    )
            with destination.open("wb") as output_stream:
                total = 0
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    total += len(chunk)
                    if expected_size is not None and total > expected_size:
                        raise ContentPackInstallError(
                            "Content-pack download exceeded the signed release byte size."
                        )
                    output_stream.write(chunk)
                output_stream.flush()
                os.fsync(output_stream.fileno())
            if expected_size is not None and total != expected_size:
                raise ContentPackInstallError(
                    "Content-pack download ended at a different byte size than the signed "
                    f"release manifest: expected {expected_size}, found {total}."
                )
    except (OSError, urllib.error.HTTPError, urllib.error.URLError) as error:
        raise ContentPackInstallError(
            f"Could not download the content pack from {url}: {error}"
        ) from error


def _canonical_json(value: object) -> str:
    def reject_floats(item: object) -> None:
        if isinstance(item, float):
            raise ContentPackInstallError("Content pack contains unsupported floating-point JSON.")
        if isinstance(item, list):
            for child in item:
                reject_floats(child)
        elif isinstance(item, dict):
            for key, child in item.items():
                if not isinstance(key, str):
                    raise ContentPackInstallError("Content pack JSON contains a non-string key.")
                reject_floats(child)

    reject_floats(value)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def _decode_canonical_json(text: object, label: str) -> object:
    if not isinstance(text, str):
        raise ContentPackInstallError(f"{label} is not JSON text.")
    try:
        value = json.loads(text)
    except (TypeError, ValueError) as error:
        raise ContentPackInstallError(f"{label} contains invalid JSON: {error}") from error
    if _canonical_json(value) != text:
        raise ContentPackInstallError(f"{label} is not canonical JSON.")
    return value


def _logical_content_digest(connection: sqlite3.Connection) -> str:
    payload = {}
    for table, columns in EXPECTED_TABLE_COLUMNS.items():
        if table == "metadata":
            continue
        quoted = ", ".join(f'"{column}"' for column in columns)
        order = ", ".join(f'"{column}"' for column in columns)
        rows = connection.execute(
            f'SELECT {quoted} FROM "{table}" ORDER BY {order}'
        ).fetchall()
        payload[table] = [
            [value.hex() if isinstance(value, bytes) else value for value in row]
            for row in rows
        ]
    return hashlib.sha256(_canonical_json(payload).encode("utf-8")).hexdigest()


def _schema_objects(connection: sqlite3.Connection) -> tuple[tuple[object, ...], ...]:
    return tuple(
        tuple(row)
        for row in connection.execute(
            "SELECT type, name, tbl_name, sql FROM sqlite_schema "
            "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name, tbl_name"
        ).fetchall()
    )


def _expected_schema_objects() -> tuple[tuple[object, ...], ...]:
    try:
        schema = SCHEMA_PATH.read_text(encoding="utf-8")
    except OSError as error:
        raise ContentPackInstallError(
            f"Could not read the pinned Entry-first schema {SCHEMA_PATH}: {error}"
        ) from error
    reference = sqlite3.connect(":memory:")
    try:
        reference.executescript(schema)
        return _schema_objects(reference)
    except sqlite3.Error as error:
        raise ContentPackInstallError(
            f"The pinned Entry-first schema is invalid: {error}"
        ) from error
    finally:
        reference.close()


def _normalize_form(value: str) -> str:
    return normalize_form_v1(value)


def _contains_exact_spelling(text: str, spelling: str) -> bool:
    return re.search(
        rf"(?<![A-Za-z0-9]){re.escape(spelling)}(?![A-Za-z0-9])",
        text,
        flags=re.IGNORECASE,
    ) is not None


def _metadata_positive_integer(metadata: Mapping[str, str], key: str) -> int:
    raw = metadata[key]
    if not re.fullmatch(r"[1-9][0-9]{0,9}", raw):
        raise ContentPackInstallError(f"Content pack metadata {key} is invalid.")
    return int(raw)


def _nonempty_text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise ContentPackInstallError(f"{label} must be nonempty text without NUL.")
    return value


def _validate_memory_cue(value: object, label: str) -> None:
    if value is None:
        return
    if not isinstance(value, dict) or set(value) != {"technique", "segments"}:
        raise ContentPackInstallError(f"{label} has an invalid memory-cue shape.")
    if value["technique"] not in MEMORY_TECHNIQUES:
        raise ContentPackInstallError(f"{label} uses an unsupported memory technique.")
    segments = value["segments"]
    if not isinstance(segments, list) or not segments or len(segments) > 12:
        raise ContentPackInstallError(f"{label} has invalid memory-cue segments.")
    for index, segment in enumerate(segments):
        if not isinstance(segment, dict) or set(segment) != {"emphasized", "text"}:
            raise ContentPackInstallError(
                f"{label} memory segment {index} has unexpected fields."
            )
        _nonempty_text(segment["text"], f"{label} memory segment {index}")
        if not isinstance(segment["emphasized"], bool):
            raise ContentPackInstallError(
                f"{label} memory segment {index} emphasis is not boolean."
            )


def validate_content_pack(path: Path) -> dict[str, object]:
    if not path.is_file():
        raise ContentPackInstallError(f"Content pack does not exist: {path}")
    reject_sqlite_sidecars(path)
    try:
        connection = sqlite3.connect(
            f"{path.resolve().as_uri()}?mode=ro&immutable=1", uri=True
        )
    except sqlite3.Error as error:
        raise ContentPackInstallError(f"Content pack is not a readable SQLite database: {error}") from error

    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only = ON")
        application_id = connection.execute("PRAGMA application_id").fetchone()[0]
        if application_id != APPLICATION_ID:
            raise ContentPackInstallError(
                "Content pack has the wrong SQLite application_id "
                f"({application_id}; expected {APPLICATION_ID})."
            )

        user_version = connection.execute("PRAGMA user_version").fetchone()[0]
        if user_version != SCHEMA_VERSION:
            raise ContentPackInstallError(
                "Content pack has unsupported schema version "
                f"{user_version} (expected {SCHEMA_VERSION})."
            )

        integrity = [row[0] for row in connection.execute("PRAGMA integrity_check")]
        if integrity != ["ok"]:
            raise ContentPackInstallError(
                "Content pack failed SQLite integrity_check: "
                + ("; ".join(str(value) for value in integrity[:10]) or "no result")
            )

        table_names = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_schema "
                "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ).fetchall()
        }
        if table_names != REQUIRED_TABLES:
            raise ContentPackInstallError(
                "Content pack schema tables do not match the Entry-first contract: "
                f"expected {sorted(REQUIRED_TABLES)}, found {sorted(table_names)}."
            )
        for table, expected_columns in EXPECTED_TABLE_COLUMNS.items():
            actual_columns = tuple(
                row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')
            )
            if actual_columns != expected_columns:
                raise ContentPackInstallError(
                    f"Content pack schema columns do not match for {table}."
                )
        if _schema_objects(connection) != _expected_schema_objects():
            raise ContentPackInstallError(
                "Content pack SQLite schema structure does not match the pinned Entry-first DDL."
            )

        public_schema = connection.execute(
            """
            SELECT lower(name), lower(COALESCE(sql, ''))
              FROM sqlite_schema
             WHERE type IN ('table', 'index', 'trigger', 'view')
            """
        ).fetchall()
        for object_name, definition in public_schema:
            searchable = f"{object_name} {definition}"
            forbidden = next(
                (value for value in FORBIDDEN_PUBLIC_IDENTIFIERS if value in searchable),
                None,
            )
            if forbidden is not None:
                raise ContentPackInstallError(
                    "Content pack crosses the public/private boundary: "
                    f"SQLite object {object_name!r} contains {forbidden!r}."
                )

        connection.execute("PRAGMA foreign_keys = ON")
        foreign_key_failures = connection.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_key_failures:
            raise ContentPackInstallError(
                "Content pack failed SQLite foreign_key_check: "
                + "; ".join(str(row) for row in foreign_key_failures[:10])
            )

        # Schema 2 reserves these tables so future releases can migrate public
        # identities without another DDL change.  The current Swift resolver
        # does not consume them yet, so accepting rows would silently ignore a
        # signed redirect or revocation.  Fail closed until predecessor-history
        # validation and runtime application ship together under a new
        # compatible resolver contract.
        unsupported_rows = [
            table
            for table in (
                "entry_migration",
                "entry_usage_disposition",
                "explanation_disposition",
            )
            if connection.execute(f'SELECT 1 FROM "{table}" LIMIT 1').fetchone()
            is not None
        ]
        if unsupported_rows:
            raise ContentPackInstallError(
                "Content pack contains migration or disposition rows that this "
                "resolver contract cannot apply: " + ", ".join(unsupported_rows)
            )

        raw_metadata = connection.execute("SELECT key, value FROM metadata").fetchall()
        if any(
            not isinstance(row[0], str) or not isinstance(row[1], str)
            for row in raw_metadata
        ):
            raise ContentPackInstallError(
                "Content pack metadata keys and values must be SQLite TEXT."
            )
        metadata = {row[0]: row[1] for row in raw_metadata}
        if len(raw_metadata) != len(metadata) or set(metadata) != METADATA_KEYS:
            raise ContentPackInstallError(
                "Content pack metadata keys do not match the schema-2 contract."
            )
        if metadata["database_kind"] != DATABASE_KIND:
            raise ContentPackInstallError("Content pack database_kind is invalid.")
        if metadata["application_id"] != str(APPLICATION_ID):
            raise ContentPackInstallError("Content pack metadata application_id is invalid.")
        if metadata["schema_version"] != str(SCHEMA_VERSION):
            raise ContentPackInstallError("Content pack metadata schema_version is invalid.")
        for key in ("content_version", "base_content_version"):
            if not metadata[key].strip() or "\x00" in metadata[key]:
                raise ContentPackInstallError(f"Content pack metadata {key} is empty.")
        if metadata["base_content_version"] != metadata["content_version"]:
            raise ContentPackInstallError(
                "Catalog base_content_version must equal content_version."
            )
        for key in ("fixture_sha256", "logical_content_digest"):
            if HASH_PATTERN.fullmatch(metadata[key]) is None:
                raise ContentPackInstallError(f"Content pack metadata {key} is invalid.")

        metadata_versions = {
            key: _metadata_positive_integer(metadata, key)
            for key in (
                "lesson_contract_version", "normalization_version",
                "resolver_contract_version", "review_policy_version",
                "usage_selection_policy_version", "validator_version",
            )
        }
        exact_contracts = {
            "lesson_contract_version": LESSON_CONTRACT_VERSION,
            "normalization_version": NORMALIZATION_VERSION,
            "resolver_contract_version": RESOLVER_CONTRACT_VERSION,
            "usage_selection_policy_version": USAGE_SELECTION_POLICY_VERSION,
        }
        for key, expected in exact_contracts.items():
            if metadata_versions[key] != expected:
                raise ContentPackInstallError(
                    f"Content pack metadata {key} is incompatible with this app."
                )
        if metadata_versions["validator_version"] < MINIMUM_VALIDATOR_VERSION:
            raise ContentPackInstallError(
                "Content pack validator_version is older than this app permits."
            )
        if metadata_versions["review_policy_version"] < MINIMUM_REVIEW_POLICY_VERSION:
            raise ContentPackInstallError(
                "Content pack review_policy_version is older than this app permits."
            )
        entry_count = connection.execute("SELECT count(*) FROM word_entry").fetchone()[0]
        usage_count = connection.execute("SELECT count(*) FROM entry_usage").fetchone()[0]
        explanation_count = connection.execute(
            "SELECT count(*) FROM released_lesson_variant"
        ).fetchone()[0]
        if min(entry_count, usage_count, explanation_count) < 1:
            raise ContentPackInstallError("Content pack contains no complete WordEntry records.")
        for key, actual in (
            ("entry_count", entry_count),
            ("usage_count", usage_count),
            ("explanation_count", explanation_count),
        ):
            if _metadata_positive_integer(metadata, key) != actual:
                raise ContentPackInstallError(
                    f"Content pack metadata {key} does not match its rows."
                )
        if usage_count != explanation_count:
            raise ContentPackInstallError(
                "Content pack must have exactly one reviewed lesson per Usage."
            )
        entry_rows = connection.execute(
            "SELECT * FROM word_entry ORDER BY language_tag, normalized_form"
        ).fetchall()
        entry_display_forms: dict[str, str] = {}
        for entry in entry_rows:
            entry_id = entry["entry_id"]
            if not isinstance(entry_id, str) or PUBLIC_ID_PATTERN.fullmatch(entry_id) is None:
                raise ContentPackInstallError("Content pack contains an invalid Entry ID.")
            display_form = _nonempty_text(
                entry["display_form"], f"Entry {entry_id} display form"
            )
            entry_display_forms[entry_id] = display_form
            normalized_form = _nonempty_text(
                entry["normalized_form"], f"Entry {entry_id} normalized form"
            )
            language = _nonempty_text(entry["language_tag"], f"Entry {entry_id} language")
            if (
                language != "en"
                or _normalize_form(display_form) != normalized_form
                or entry["normalization_version"]
                    != metadata_versions["normalization_version"]
                or not isinstance(entry["entry_revision"], int)
                or entry["entry_revision"] < 1
                or not isinstance(entry["entry_rank"], int)
                or entry["entry_rank"] < 0
            ):
                raise ContentPackInstallError(
                    f"Content pack Entry {entry_id} has invalid identity or revision fields."
                )
        invalid_entry_version = connection.execute(
            "SELECT entry_id FROM word_entry WHERE normalization_version <> ? LIMIT 1",
            (metadata_versions["normalization_version"],),
        ).fetchone()
        if invalid_entry_version is not None:
            raise ContentPackInstallError(
                f"Content pack Entry {invalid_entry_version[0]} has an incompatible normalization version."
            )

        coverage_rows = connection.execute(
            """
            SELECT ec.*, we.language_tag, we.normalized_form
              FROM entry_coverage AS ec
              JOIN word_entry AS we ON we.entry_id = ec.entry_id
             ORDER BY we.language_tag, we.normalized_form, ec.locale
            """
        ).fetchall()
        if len(coverage_rows) != entry_count:
            raise ContentPackInstallError(
                "Content pack must have exactly one coverage row for every Entry."
            )
        locales: set[str] = set()
        for coverage in coverage_rows:
            locales.add(str(coverage["locale"]))
            if (
                coverage["locale"] not in SUPPORTED_CONTENT_LOCALES
                or not isinstance(coverage["coverage_revision"], int)
                or coverage["coverage_revision"] < 1
                or not isinstance(coverage["expected_core_count"], int)
                or not (1 <= coverage["expected_core_count"] <= 4)
            ):
                raise ContentPackInstallError(
                    f"Content pack has unsupported locale or coverage bounds for {coverage['entry_id']}."
                )
            if (
                coverage["coverage_state"] != "releaseReviewedComplete"
                or coverage["content_version"] != metadata["content_version"]
                or coverage["lesson_contract_version"]
                    != metadata_versions["lesson_contract_version"]
                or coverage["validator_version"] != metadata_versions["validator_version"]
                or coverage["review_policy_version"]
                    != metadata_versions["review_policy_version"]
                or coverage["usage_selection_policy_version"]
                    != metadata_versions["usage_selection_policy_version"]
                or coverage["available_usage_count"] != coverage["expected_usage_count"]
                or coverage["has_more_usages"]
                    != int(coverage["expected_usage_count"] > coverage["expected_core_count"])
            ):
                raise ContentPackInstallError(
                    "Content pack has incomplete Entry coverage or incompatible release "
                    f"contracts for {coverage['entry_id']}."
                )
            usages = connection.execute(
                "SELECT entry_usage_id, language_tag, normalized_form, "
                "part_of_speech_label, learner_label, pronunciation_json, "
                "form_relation_label, context_vector_format_version, context_vector, "
                "display_order, commonness_rank, is_core "
                "FROM entry_usage WHERE entry_id = ? ORDER BY display_order",
                (coverage["entry_id"],),
            ).fetchall()
            expected_count = int(coverage["expected_usage_count"])
            expected_core = int(coverage["expected_core_count"])
            if [row["display_order"] for row in usages] != list(range(expected_count)):
                raise ContentPackInstallError(
                    f"Content pack Entry {coverage['entry_id']} lacks contiguous Usage order."
                )
            if len(usages) != expected_count or [row["is_core"] for row in usages] != [
                int(index < expected_core) for index in range(expected_count)
            ]:
                raise ContentPackInstallError(
                    f"Content pack Entry {coverage['entry_id']} has false core coverage."
                )
            for usage in usages:
                usage_id = usage["entry_usage_id"]
                if (
                    not isinstance(usage_id, str)
                    or PUBLIC_ID_PATTERN.fullmatch(usage_id) is None
                    or usage["language_tag"] != coverage["language_tag"]
                    or usage["normalized_form"] != coverage["normalized_form"]
                    or not isinstance(usage["commonness_rank"], int)
                    or usage["commonness_rank"] < 1
                    or (
                        usage["context_vector_format_version"] is None
                        and usage["context_vector"] is not None
                    )
                    or usage["context_vector_format_version"] is not None
                ):
                    raise ContentPackInstallError(
                        f"Usage {usage_id} has invalid identity, rank, or context fields."
                    )
                for field in (
                    "part_of_speech_label", "learner_label", "form_relation_label"
                ):
                    if usage[field] is not None:
                        _nonempty_text(usage[field], f"Usage {usage_id} {field}")
                pronunciations = _decode_canonical_json(
                    usage["pronunciation_json"],
                    f"Usage {usage_id} pronunciation_json",
                )
                if not isinstance(pronunciations, list):
                    raise ContentPackInstallError(
                        f"Usage {usage_id} pronunciations are not an array."
                    )
                for index, pronunciation in enumerate(pronunciations):
                    if not isinstance(pronunciation, dict) or set(pronunciation) != {
                        "ipa", "locale"
                    }:
                        raise ContentPackInstallError(
                            f"Usage {usage_id} pronunciation {index} has invalid fields."
                        )
                    _nonempty_text(
                        pronunciation["ipa"], f"Usage {usage_id} pronunciation IPA"
                    )
                    _nonempty_text(
                        pronunciation["locale"],
                        f"Usage {usage_id} pronunciation locale",
                    )
            defaults = connection.execute(
                "SELECT count(*) FROM entry_default WHERE entry_id = ? AND locale = ?",
                (coverage["entry_id"], coverage["locale"]),
            ).fetchone()[0]
            if defaults != expected_count:
                raise ContentPackInstallError(
                    f"Content pack Entry {coverage['entry_id']} lacks a released default."
                )
        if tuple(sorted(locales)) != SUPPORTED_CONTENT_LOCALES:
            raise ContentPackInstallError(
                "Content pack locales are incompatible with this app."
            )

        lesson_rows = connection.execute(
            """
            SELECT we.entry_id, we.language_tag, we.normalized_form,
                   lv.entry_usage_id, lv.locale, lv.schema_version,
                   lv.lesson_contract_version, lv.validator_version,
                   lv.review_policy_version, lv.content_revision, lv.explanation_id,
                   lv.content_hash, lv.direct_explanation, lv.example,
                   lv.synonyms_json, lv.memory_cue_json, lv.trust_state
              FROM released_lesson_variant AS lv
              JOIN word_entry AS we ON we.entry_id = lv.entry_id
            """
        ).fetchall()
        if not lesson_rows:
            raise ContentPackInstallError("Content pack contains no released lessons.")
        for row in lesson_rows:
            (
                entry_id,
                language,
                normalized_form,
                entry_usage_id,
                locale,
                schema_version,
                lesson_contract_version,
                validator_version,
                review_policy_version,
                content_revision,
                explanation_id,
                content_hash,
                direct_explanation,
                example,
                synonyms_json,
                memory_cue_json,
                trust_state,
            ) = row
            if (
                not isinstance(explanation_id, str)
                or not explanation_id.startswith("exp_")
                or not isinstance(content_hash, str)
                or HASH_PATTERN.fullmatch(content_hash) is None
                or locale not in SUPPORTED_CONTENT_LOCALES
                or not isinstance(content_revision, int)
                or content_revision < 1
            ):
                raise ContentPackInstallError(
                    f"Lesson {explanation_id} has invalid identity or revision fields."
                )
            direct_explanation = _nonempty_text(
                direct_explanation, f"Lesson {explanation_id} direct explanation"
            )
            example = _nonempty_text(example, f"Lesson {explanation_id} example")
            if direct_explanation.casefold().startswith(("this word", "the word", "it means")):
                raise ContentPackInstallError(
                    f"Lesson {explanation_id} does not begin with a direct explanation."
                )
            display_form = entry_display_forms[entry_id]
            if not _contains_exact_spelling(example, display_form):
                raise ContentPackInstallError(
                    f"Lesson {explanation_id} example does not use the Entry spelling."
                )
            synonyms = _decode_canonical_json(
                synonyms_json, f"Lesson {explanation_id} synonyms_json"
            )
            memory_cue = None if memory_cue_json is None else _decode_canonical_json(
                memory_cue_json, f"Lesson {explanation_id} memory_cue_json"
            )
            if (
                not isinstance(synonyms, list)
                or any(
                    not isinstance(value, str) or not value.strip() or "\x00" in value
                    for value in synonyms
                )
                or len({_normalize_form(value) for value in synonyms}) != len(synonyms)
                or (memory_cue is not None and not isinstance(memory_cue, dict))
                or trust_state != "releaseReviewed"
                or schema_version != SCHEMA_VERSION
                or lesson_contract_version != metadata_versions["lesson_contract_version"]
                or validator_version != metadata_versions["validator_version"]
                or review_policy_version != metadata_versions["review_policy_version"]
            ):
                raise ContentPackInstallError(
                    f"Lesson {explanation_id} is incompatible with the release contract."
                )
            _validate_memory_cue(memory_cue, f"Lesson {explanation_id}")
            envelope = {
                "directExplanation": direct_explanation,
                "entryID": entry_id,
                "entryUsageID": entry_usage_id,
                "example": example,
                "language": language,
                "lessonContractVersion": lesson_contract_version,
                "locale": locale,
                "memoryCue": memory_cue,
                "normalizedForm": normalized_form,
                "schemaVersion": schema_version,
                "synonyms": synonyms,
            }
            canonical = _canonical_json(envelope).encode("utf-8")
            expected_hash = hashlib.sha256(canonical).hexdigest()
            if content_hash != expected_hash or explanation_id != f"exp_{expected_hash}":
                raise ContentPackInstallError(
                    f"Lesson {explanation_id} has a mismatched immutable content hash."
                )
        logical_digest = _logical_content_digest(connection)
        if logical_digest != metadata["logical_content_digest"]:
            raise ContentPackInstallError(
                "Content pack logical content digest does not match its rows."
            )
        return {
            "applicationID": application_id,
            "baseContentVersion": metadata["base_content_version"],
            "contentVersion": metadata["content_version"],
            "databaseKind": metadata["database_kind"],
            "entries": entry_count,
            "explanations": explanation_count,
            "fixtureSHA256": metadata["fixture_sha256"],
            "lessonContractVersion": metadata_versions["lesson_contract_version"],
            "locales": sorted(locales),
            "logicalContentDigest": logical_digest,
            "normalizationVersion": metadata_versions["normalization_version"],
            "resolverContractVersion": metadata_versions["resolver_contract_version"],
            "reviewPolicyVersion": metadata_versions["review_policy_version"],
            "schemaVersion": user_version,
            "usageSelectionPolicyVersion": metadata_versions[
                "usage_selection_policy_version"
            ],
            "usages": usage_count,
            "validatorVersion": metadata_versions["validator_version"],
        }
    except sqlite3.Error as error:
        raise ContentPackInstallError(f"Could not validate the SQLite content pack: {error}") from error
    finally:
        connection.close()


def verify_digest(path: Path, expected_sha256: str) -> None:
    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected_sha256:
        raise ContentPackInstallError(
            "Content-pack SHA-256 mismatch: "
            f"expected {expected_sha256}, found {actual_sha256}. The file was not installed."
        )


def install_content_pack(
    *,
    destination: Path,
    expected_sha256: str,
    source: Optional[Path] = None,
    url: Optional[str] = None,
    expected_size: Optional[int] = None,
) -> str:
    digest = normalize_sha256(expected_sha256)
    if (source is None) == (url is None):
        raise ContentPackInstallError("Choose exactly one content-pack source or URL.")
    if expected_size is not None and expected_size <= 0:
        raise ContentPackInstallError("The expected content-pack byte size must be positive.")

    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        reject_sqlite_sidecars(destination)
        file_descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
        )
        os.close(file_descriptor)
    except OSError as error:
        raise ContentPackInstallError(
            f"Could not create a staging file beside {destination}: {error}"
        ) from error

    temporary_path = Path(temporary_name)
    try:
        if source is not None:
            copy_local_source(source, temporary_path, expected_size=expected_size)
        else:
            assert url is not None
            download_https(url, temporary_path, expected_size=expected_size)

        verify_digest(temporary_path, digest)
        validate_content_pack(temporary_path)
        try:
            os.chmod(temporary_path, 0o644)
            os.replace(temporary_path, destination)
            fsync_directory(destination.parent)
        except OSError as error:
            raise ContentPackInstallError(
                f"Could not atomically install the content pack at {destination}: {error}"
            ) from error
    finally:
        temporary_path.unlink(missing_ok=True)

    return digest


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    location = parser.add_mutually_exclusive_group()
    location.add_argument("--source", help="path to an already-generated content-pack SQLite file")
    location.add_argument("--url", help="HTTPS URL of a published content-pack SQLite file")
    parser.add_argument(
        "--sha256",
        help=f"pinned SHA-256 (required; environment default: {SHA256_ENV})",
    )
    return parser


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parsed = build_argument_parser().parse_args(arguments)
    source, url = resolve_input(
        source_argument=parsed.source,
        url_argument=parsed.url,
        environment=os.environ,
    )
    digest = install_content_pack(
        destination=CONTENT_PACK_PATH,
        expected_sha256=parsed.sha256 or os.environ.get(SHA256_ENV),
        source=source,
        url=url,
    )
    print(f"Wordbook content pack is ready: {CONTENT_PACK_PATH}")
    print(f"SHA-256: {digest}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ContentPackInstallError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
