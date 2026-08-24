#!/usr/bin/env python3
"""Fail a production client build unless its bundled Entry catalog is trusted.

This is deliberately a read-only, Python-standard-library build gate.  The
normal path consumes the durable build receipt emitted only after
``install_signed_content_release.py`` has authenticated a release manifest and
atomically activated the exact SQLite artifact.  CI may instead provide the
same expectations explicitly through the environment variables documented
below.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
from typing import Any, Mapping, Optional, Sequence


APPLICATION_ID = 1_463_960_400
SCHEMA_VERSION = 2
BUILD_RECEIPT_VERSION = 1
DATABASE_KIND = "entry_content_pack"
MAX_RECEIPT_BYTES = 64 * 1024
CHUNK_SIZE = 4 * 1024 * 1024

KNOWN_FIXTURE_ARTIFACT_SHA256 = (
    "d9aaac725b01e11f3e258e3768fa90c5c887158e360c2d65e7b6be1e61748c15"
)
KNOWN_FIXTURE_CONTENT_VERSION = "entry-golden-2026-08-23"
KNOWN_FIXTURE_SOURCE_SHA256 = (
    "b8a8a43655f3a79d59ab59d9d8706bb6cfd25d315ea860e4c191fbc0cbe0184a"
)

SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
KEY_ID_PATTERN = re.compile(r"^ssh-ed25519-sha256:[0-9a-f]{64}$")

REQUIRED_TABLES = frozenset(
    {
        "entry_coverage",
        "entry_default",
        "entry_usage",
        "metadata",
        "released_lesson_variant",
        "word_entry",
    }
)
REQUIRED_METADATA_KEYS = frozenset(
    {
        "application_id",
        "base_content_version",
        "content_version",
        "database_kind",
        "entry_count",
        "explanation_count",
        "fixture_sha256",
        "lesson_contract_version",
        "logical_content_digest",
        "normalization_version",
        "resolver_contract_version",
        "review_policy_version",
        "schema_version",
        "usage_count",
        "usage_selection_policy_version",
        "validator_version",
    }
)
CONTRACT_KEYS = frozenset(
    {
        "lessonContractVersion",
        "normalizationVersion",
        "resolverContractVersion",
        "reviewPolicyVersion",
        "schemaVersion",
        "usageSelectionPolicyVersion",
        "validatorVersion",
    }
)
COUNT_KEYS = frozenset({"entries", "explanations", "usages"})
BUILD_RECEIPT_KEYS = frozenset(
    {
        "artifactSHA256",
        "artifactSizeBytes",
        "buildReceiptVersion",
        "contentVersion",
        "contracts",
        "counts",
        "fixtureSHA256",
        "logicalContentDigest",
        "manifestSHA256",
        "minimumAppBuild",
        "releaseSequence",
        "signatureKeyID",
    }
)

EXPECTED_SHA256_ENV = "WORDBOOK_CONTENT_EXPECTED_SHA256"
EXPECTED_CONTENT_VERSION_ENV = "WORDBOOK_CONTENT_EXPECTED_CONTENT_VERSION"
EXPECTED_ENTRY_COUNT_ENV = "WORDBOOK_CONTENT_EXPECTED_ENTRY_COUNT"
EXPECTED_USAGE_COUNT_ENV = "WORDBOOK_CONTENT_EXPECTED_USAGE_COUNT"
EXPECTED_EXPLANATION_COUNT_ENV = "WORDBOOK_CONTENT_EXPECTED_EXPLANATION_COUNT"
EXPECTED_MINIMUM_APP_BUILD_ENV = "WORDBOOK_CONTENT_EXPECTED_MINIMUM_APP_BUILD"
EXPLICIT_EXPECTATION_ENVIRONMENTS = (
    EXPECTED_SHA256_ENV,
    EXPECTED_CONTENT_VERSION_ENV,
    EXPECTED_ENTRY_COUNT_ENV,
    EXPECTED_USAGE_COUNT_ENV,
    EXPECTED_EXPLANATION_COUNT_ENV,
    EXPECTED_MINIMUM_APP_BUILD_ENV,
)


class ReleaseContentValidationError(RuntimeError):
    """The client must not be released with this content artifact."""


def _canonical_json(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")


def _bounded_positive_integer(
    value: Any, label: str, maximum: int = 20_000_000
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ReleaseContentValidationError(f"{label} must be an integer")
    if not 1 <= value <= maximum:
        raise ReleaseContentValidationError(f"{label} is outside the supported range")
    return value


def _environment_positive_integer(value: str, label: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise ReleaseContentValidationError(f"{label} must be an integer") from error
    return _bounded_positive_integer(parsed, label, 2_147_483_647)


def _read_regular_file(path: Path, *, maximum: Optional[int], label: str) -> bytes:
    try:
        status = path.lstat()
    except OSError as error:
        raise ReleaseContentValidationError(f"{label} is unavailable: {path}: {error}") from error
    if stat.S_ISLNK(status.st_mode) or not stat.S_ISREG(status.st_mode):
        raise ReleaseContentValidationError(f"{label} must be a regular, non-symlink file: {path}")
    if maximum is not None and status.st_size > maximum:
        raise ReleaseContentValidationError(f"{label} exceeds {maximum} bytes")
    try:
        return path.read_bytes()
    except OSError as error:
        raise ReleaseContentValidationError(f"{label} is unreadable: {path}: {error}") from error


def _require_readable_regular_file(path: Path, *, label: str) -> os.stat_result:
    try:
        status = path.lstat()
    except OSError as error:
        raise ReleaseContentValidationError(f"{label} is unavailable: {path}: {error}") from error
    if stat.S_ISLNK(status.st_mode) or not stat.S_ISREG(status.st_mode):
        raise ReleaseContentValidationError(f"{label} must be a regular, non-symlink file: {path}")
    try:
        with path.open("rb") as stream:
            stream.read(1)
    except OSError as error:
        raise ReleaseContentValidationError(f"{label} is unreadable: {path}: {error}") from error
    return status


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(CHUNK_SIZE):
                digest.update(chunk)
    except OSError as error:
        raise ReleaseContentValidationError(
            f"content pack is unreadable: {path}: {error}"
        ) from error
    return digest.hexdigest()


def _exact_object(value: Any, keys: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ReleaseContentValidationError(f"{label} has missing or unexpected fields")
    return value


def load_build_receipt(path: Path) -> dict[str, Any]:
    payload = _read_regular_file(
        path, maximum=MAX_RECEIPT_BYTES, label="signed-release build receipt"
    )
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseContentValidationError(
            f"signed-release build receipt is not valid UTF-8 JSON: {error}"
        ) from error
    if _canonical_json(decoded) != payload:
        raise ReleaseContentValidationError(
            "signed-release build receipt is not byte-canonical JSON"
        )
    receipt = _exact_object(decoded, BUILD_RECEIPT_KEYS, "signed-release build receipt")
    if receipt["buildReceiptVersion"] != BUILD_RECEIPT_VERSION:
        raise ReleaseContentValidationError("signed-release build receipt version is unsupported")
    for key in ("artifactSHA256", "fixtureSHA256", "logicalContentDigest", "manifestSHA256"):
        if not isinstance(receipt[key], str) or SHA256_PATTERN.fullmatch(receipt[key]) is None:
            raise ReleaseContentValidationError(f"build receipt {key} is not a SHA-256")
    if (
        not isinstance(receipt["signatureKeyID"], str)
        or KEY_ID_PATTERN.fullmatch(receipt["signatureKeyID"]) is None
    ):
        raise ReleaseContentValidationError("build receipt signing key ID is invalid")
    if (
        not isinstance(receipt["contentVersion"], str)
        or not receipt["contentVersion"].strip()
        or "\x00" in receipt["contentVersion"]
    ):
        raise ReleaseContentValidationError("build receipt content version is invalid")
    _bounded_positive_integer(
        receipt["artifactSizeBytes"], "build receipt artifact size", 2 * 1024 * 1024 * 1024
    )
    _bounded_positive_integer(
        receipt["minimumAppBuild"], "build receipt minimum app build", 2_147_483_647
    )
    _bounded_positive_integer(
        receipt["releaseSequence"], "build receipt release sequence", 9_223_372_036_854_775_807
    )
    contracts = _exact_object(receipt["contracts"], CONTRACT_KEYS, "build receipt contracts")
    for key, value in contracts.items():
        _bounded_positive_integer(value, f"build receipt contract {key}")
    counts = _exact_object(receipt["counts"], COUNT_KEYS, "build receipt counts")
    entries = _bounded_positive_integer(counts["entries"], "build receipt Entry count")
    usages = _bounded_positive_integer(counts["usages"], "build receipt Usage count")
    explanations = _bounded_positive_integer(
        counts["explanations"], "build receipt explanation count"
    )
    if usages < entries or explanations != usages:
        raise ReleaseContentValidationError("build receipt counts are internally inconsistent")
    return receipt


def explicit_expectations(environment: Mapping[str, str]) -> dict[str, Any]:
    missing = [name for name in EXPLICIT_EXPECTATION_ENVIRONMENTS if not environment.get(name)]
    if missing:
        raise ReleaseContentValidationError(
            "no signed-release build receipt was supplied, and explicit release "
            "expectations are incomplete: " + ", ".join(missing)
        )
    digest = environment[EXPECTED_SHA256_ENV]
    if SHA256_PATTERN.fullmatch(digest) is None:
        raise ReleaseContentValidationError(f"{EXPECTED_SHA256_ENV} is not a SHA-256")
    content_version = environment[EXPECTED_CONTENT_VERSION_ENV]
    if not content_version.strip() or "\x00" in content_version:
        raise ReleaseContentValidationError(
            f"{EXPECTED_CONTENT_VERSION_ENV} is invalid"
        )
    return {
        "artifactSHA256": digest,
        "artifactSizeBytes": None,
        "contentVersion": content_version,
        "contracts": None,
        "counts": {
            "entries": _environment_positive_integer(
                environment[EXPECTED_ENTRY_COUNT_ENV], EXPECTED_ENTRY_COUNT_ENV
            ),
            "usages": _environment_positive_integer(
                environment[EXPECTED_USAGE_COUNT_ENV], EXPECTED_USAGE_COUNT_ENV
            ),
            "explanations": _environment_positive_integer(
                environment[EXPECTED_EXPLANATION_COUNT_ENV],
                EXPECTED_EXPLANATION_COUNT_ENV,
            ),
        },
        "fixtureSHA256": None,
        "logicalContentDigest": None,
        "minimumAppBuild": _environment_positive_integer(
            environment[EXPECTED_MINIMUM_APP_BUILD_ENV],
            EXPECTED_MINIMUM_APP_BUILD_ENV,
        ),
    }


def _metadata_positive_integer(metadata: Mapping[str, str], key: str) -> int:
    try:
        value = int(metadata[key])
    except ValueError as error:
        raise ReleaseContentValidationError(f"content metadata {key} is not an integer") from error
    return _bounded_positive_integer(value, f"content metadata {key}")


def _reject_known_fixture(
    *, artifact_sha256: str, content_version: str, fixture_sha256: str, counts: Mapping[str, int]
) -> None:
    if artifact_sha256 == KNOWN_FIXTURE_ARTIFACT_SHA256:
        raise ReleaseContentValidationError("the known 7-Entry fixture cannot ship in Release")
    if content_version == KNOWN_FIXTURE_CONTENT_VERSION:
        raise ReleaseContentValidationError("the known fixture content version cannot ship in Release")
    if (
        fixture_sha256 == KNOWN_FIXTURE_SOURCE_SHA256
        and counts == {"entries": 7, "usages": 13, "explanations": 13}
    ):
        raise ReleaseContentValidationError("the known 7-Entry fixture cannot ship in Release")


def validate_content_pack(
    *,
    pack_path: Path,
    expectations: Mapping[str, Any],
    current_app_build: int,
) -> dict[str, Any]:
    _bounded_positive_integer(current_app_build, "current app build", 2_147_483_647)
    pack_status = _require_readable_regular_file(pack_path, label="content pack")
    for suffix in ("-journal", "-shm", "-wal"):
        if Path(str(pack_path) + suffix).exists():
            raise ReleaseContentValidationError(
                f"content pack is not standalone; SQLite sidecar exists: {pack_path}{suffix}"
            )
    actual_size = pack_status.st_size
    actual_digest = sha256_file(pack_path)
    if actual_digest != expectations["artifactSHA256"]:
        raise ReleaseContentValidationError(
            "content pack SHA-256 does not match the authenticated release expectation"
        )
    expected_size = expectations.get("artifactSizeBytes")
    if expected_size is not None and actual_size != expected_size:
        raise ReleaseContentValidationError(
            "content pack size does not match the authenticated release expectation"
        )
    if current_app_build < expectations["minimumAppBuild"]:
        raise ReleaseContentValidationError(
            "content release requires app build "
            f"{expectations['minimumAppBuild']}; current build is {current_app_build}"
        )

    uri = pack_path.resolve().as_uri() + "?mode=ro&immutable=1"
    try:
        connection = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as error:
        raise ReleaseContentValidationError(f"could not open content pack read-only: {error}") from error
    try:
        connection.execute("PRAGMA query_only = ON")
        application_id = connection.execute("PRAGMA application_id").fetchone()[0]
        user_version = connection.execute("PRAGMA user_version").fetchone()[0]
        if application_id != APPLICATION_ID:
            raise ReleaseContentValidationError("content pack application_id is invalid")
        if user_version != SCHEMA_VERSION:
            raise ReleaseContentValidationError(
                f"content pack schema is {user_version}; Release requires schema {SCHEMA_VERSION}"
            )

        integrity_rows = connection.execute("PRAGMA integrity_check").fetchall()
        if integrity_rows != [("ok",)]:
            raise ReleaseContentValidationError("content pack failed SQLite integrity_check")
        foreign_key_failure = connection.execute("PRAGMA foreign_key_check").fetchone()
        if foreign_key_failure is not None:
            raise ReleaseContentValidationError("content pack failed SQLite foreign_key_check")

        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_schema WHERE type = 'table'"
            )
        }
        missing_tables = sorted(REQUIRED_TABLES - tables)
        if missing_tables:
            raise ReleaseContentValidationError(
                "content pack is missing required tables: " + ", ".join(missing_tables)
            )

        raw_metadata = connection.execute("SELECT key, value FROM metadata").fetchall()
        if any(not isinstance(key, str) or not isinstance(value, str) for key, value in raw_metadata):
            raise ReleaseContentValidationError("content metadata must contain only text")
        metadata = dict(raw_metadata)
        if len(metadata) != len(raw_metadata) or set(metadata) != REQUIRED_METADATA_KEYS:
            raise ReleaseContentValidationError(
                "content pack metadata does not match the schema-2 release contract"
            )
        if metadata["database_kind"] != DATABASE_KIND:
            raise ReleaseContentValidationError("content pack database_kind is invalid")
        if metadata["application_id"] != str(APPLICATION_ID):
            raise ReleaseContentValidationError("content metadata application_id is invalid")
        if metadata["schema_version"] != str(SCHEMA_VERSION):
            raise ReleaseContentValidationError("content metadata schema_version is invalid")
        if metadata["base_content_version"] != metadata["content_version"]:
            raise ReleaseContentValidationError("content base/content versions differ")
        for key in ("fixture_sha256", "logical_content_digest"):
            if SHA256_PATTERN.fullmatch(metadata[key]) is None:
                raise ReleaseContentValidationError(f"content metadata {key} is invalid")

        contract_values = {
            "lessonContractVersion": _metadata_positive_integer(
                metadata, "lesson_contract_version"
            ),
            "normalizationVersion": _metadata_positive_integer(
                metadata, "normalization_version"
            ),
            "resolverContractVersion": _metadata_positive_integer(
                metadata, "resolver_contract_version"
            ),
            "reviewPolicyVersion": _metadata_positive_integer(
                metadata, "review_policy_version"
            ),
            "schemaVersion": _metadata_positive_integer(metadata, "schema_version"),
            "usageSelectionPolicyVersion": _metadata_positive_integer(
                metadata, "usage_selection_policy_version"
            ),
            "validatorVersion": _metadata_positive_integer(metadata, "validator_version"),
        }
        if (
            contract_values["lessonContractVersion"] != 2
            or contract_values["normalizationVersion"] != 1
            or contract_values["resolverContractVersion"] != 1
            or contract_values["schemaVersion"] != 2
            or contract_values["usageSelectionPolicyVersion"] != 1
            or contract_values["validatorVersion"] < 2
            or contract_values["reviewPolicyVersion"] < 5
        ):
            raise ReleaseContentValidationError("content metadata contracts are incompatible")
        expected_contracts = expectations.get("contracts")
        if expected_contracts is not None and contract_values != expected_contracts:
            raise ReleaseContentValidationError(
                "content contracts do not match the authenticated release receipt"
            )

        counts = {
            "entries": connection.execute("SELECT count(*) FROM word_entry").fetchone()[0],
            "usages": connection.execute("SELECT count(*) FROM entry_usage").fetchone()[0],
            "explanations": connection.execute(
                "SELECT count(*) FROM released_lesson_variant"
            ).fetchone()[0],
        }
        metadata_counts = {
            "entries": _metadata_positive_integer(metadata, "entry_count"),
            "usages": _metadata_positive_integer(metadata, "usage_count"),
            "explanations": _metadata_positive_integer(metadata, "explanation_count"),
        }
        if counts != metadata_counts:
            raise ReleaseContentValidationError("content metadata counts do not match its rows")
        expected_counts = expectations["counts"]
        below = [name for name in COUNT_KEYS if counts[name] < expected_counts[name]]
        if below:
            raise ReleaseContentValidationError(
                "content pack counts are below the authenticated release expectation: "
                + ", ".join(sorted(below))
            )
        if expectations.get("artifactSizeBytes") is not None and counts != expected_counts:
            raise ReleaseContentValidationError(
                "content pack counts differ from the authenticated signed manifest"
            )
        if counts["usages"] != counts["explanations"]:
            raise ReleaseContentValidationError(
                "content pack must have one reviewed explanation per Usage"
            )
    except sqlite3.Error as error:
        raise ReleaseContentValidationError(
            f"could not validate content pack SQLite data: {error}"
        ) from error
    finally:
        connection.close()

    if metadata["content_version"] != expectations["contentVersion"]:
        raise ReleaseContentValidationError(
            "content version does not match the authenticated release expectation"
        )
    expected_fixture = expectations.get("fixtureSHA256")
    if expected_fixture is not None and metadata["fixture_sha256"] != expected_fixture:
        raise ReleaseContentValidationError(
            "content fixture digest does not match the authenticated release receipt"
        )
    expected_logical = expectations.get("logicalContentDigest")
    if expected_logical is not None and metadata["logical_content_digest"] != expected_logical:
        raise ReleaseContentValidationError(
            "content logical digest does not match the authenticated release receipt"
        )
    _reject_known_fixture(
        artifact_sha256=actual_digest,
        content_version=metadata["content_version"],
        fixture_sha256=metadata["fixture_sha256"],
        counts=counts,
    )
    return {
        "artifactSHA256": actual_digest,
        "contentVersion": metadata["content_version"],
        "counts": counts,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--app-build", type=int, required=True)
    return parser


def main(
    argv: Optional[Sequence[str]] = None,
    environment: Optional[Mapping[str, str]] = None,
) -> int:
    arguments = build_parser().parse_args(argv)
    values = os.environ if environment is None else environment
    if arguments.receipt is not None:
        unexpected = [name for name in EXPLICIT_EXPECTATION_ENVIRONMENTS if values.get(name)]
        if unexpected:
            raise ReleaseContentValidationError(
                "do not mix a signed-release build receipt with explicit expectations: "
                + ", ".join(unexpected)
            )
        expectations = load_build_receipt(arguments.receipt.expanduser().resolve())
    else:
        expectations = explicit_expectations(values)
    summary = validate_content_pack(
        pack_path=arguments.pack.expanduser().resolve(),
        expectations=expectations,
        current_app_build=arguments.app_build,
    )
    print(
        "Validated Release content pack "
        f"{summary['contentVersion']} ({summary['artifactSHA256']})"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReleaseContentValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
