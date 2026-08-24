#!/usr/bin/env python3
"""Verify a signed Wordbook content release and atomically install its pack.

The release manifest and SSHSIG signature may be local files or HTTPS URLs.
The OpenSSH ``allowed_signers`` trust root is always a local, independently
provisioned file; a public key delivered beside the release is never trusted.
Only after signature and strict manifest validation does this tool use the
manifest's artifact URL, SHA-256, and exact byte size.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Mapping, Optional, Sequence
from urllib.parse import unquote, urlsplit
import urllib.error
import urllib.request

import install_content_pack


MANIFEST_VERSION = 1
STATE_VERSION = 1
BUILD_RECEIPT_VERSION = 1
SIGNATURE_NAMESPACE = "wordbook-content-release-v1"
MAX_MANIFEST_BYTES = 128 * 1024
MAX_SIGNATURE_BYTES = 32 * 1024
MAX_PACK_BYTES = 2 * 1024 * 1024 * 1024
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ATTESTATION_PATTERN = re.compile(r"^rel_[0-9a-f]{64}$")
IDENTITY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$")
KEY_ID_PATTERN = re.compile(r"^ssh-ed25519-sha256:[0-9a-f]{64}$")
LOCALE_PATTERN = re.compile(r"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$")
ROLLBACK_REASON_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
CREATED_AT_PATTERN = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
)

ROOT_KEYS = frozenset(
    {
        "artifact",
        "contentVersion",
        "contracts",
        "counts",
        "createdAt",
        "fixtureSHA256",
        "locales",
        "logicalContentDigest",
        "manifestVersion",
        "minimumAppBuild",
        "releaseAttestationID",
        "releaseSequence",
        "rollbackAuthorization",
        "signature",
        "targetManifestSHA256",
    }
)
ARTIFACT_KEYS = frozenset(
    {
        "compressedSHA256",
        "compressedSizeBytes",
        "compression",
        "downloadURL",
        "fileName",
        "uncompressedSHA256",
        "uncompressedSizeBytes",
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
SIGNATURE_KEYS = frozenset(
    {"algorithm", "fileName", "identity", "keyID", "namespace"}
)
ROLLBACK_KEYS = frozenset({"fromReleaseSequence", "reasonCode"})
STATE_KEYS = frozenset(
    {
        "artifactSHA256",
        "contentVersion",
        "highestAcceptedReleaseSequence",
        "keyID",
        "manifestSHA256",
        "releaseSequence",
        "stateVersion",
    }
)
PENDING_KEYS = frozenset(
    {
        "pendingVersion",
        "previousArtifactSHA256",
        "targetArtifactSHA256",
        "targetManifestSHA256",
        "targetReleaseSequence",
    }
)
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

MANIFEST_URL_ENV = "WORDBOOK_CONTENT_MANIFEST_URL"
SIGNATURE_URL_ENV = "WORDBOOK_CONTENT_SIGNATURE_URL"
ALLOWED_SIGNERS_ENV = "WORDBOOK_CONTENT_ALLOWED_SIGNERS"
APP_BUILD_ENV = "WORDBOOK_APP_BUILD"
ROLLBACK_KEY_IDS_ENV = "WORDBOOK_CONTENT_ROLLBACK_KEY_IDS"
BUILD_RECEIPT_PATH_ENV = "WORDBOOK_CONTENT_BUILD_RECEIPT_PATH"


class SignedReleaseInstallError(RuntimeError):
    """The signed release cannot be authenticated or installed safely."""


def _canonical_json(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        + "\n"
    ).encode("utf-8")


def _read_local_bounded(path: Path, maximum: int, label: str) -> bytes:
    path = path.expanduser()
    if not path.is_file():
        raise SignedReleaseInstallError(f"{label} does not exist: {path}")
    if path.stat().st_size > maximum:
        raise SignedReleaseInstallError(f"{label} exceeds the {maximum}-byte limit")
    try:
        return path.read_bytes()
    except OSError as error:
        raise SignedReleaseInstallError(f"could not read {label}: {error}") from error


def _download_bounded(url: str, maximum: int, label: str) -> bytes:
    url = install_content_pack.validate_https_url(url)
    request = urllib.request.Request(
        url,
        headers={"Accept-Encoding": "identity", "User-Agent": "Wordbook-signed-release/1"},
    )
    result = bytearray()
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            install_content_pack.validate_https_url(response.geturl())
            declared = response.headers.get("Content-Length")
            if declared is not None:
                try:
                    declared_size = int(declared)
                except ValueError as error:
                    raise SignedReleaseInstallError(
                        f"{label} server returned an invalid Content-Length"
                    ) from error
                if declared_size < 0 or declared_size > maximum:
                    raise SignedReleaseInstallError(
                        f"{label} exceeds the {maximum}-byte limit"
                    )
            while True:
                chunk = response.read(min(16 * 1024, maximum + 1 - len(result)))
                if not chunk:
                    break
                result.extend(chunk)
                if len(result) > maximum:
                    raise SignedReleaseInstallError(
                        f"{label} exceeds the {maximum}-byte limit"
                    )
    except SignedReleaseInstallError:
        raise
    except (OSError, urllib.error.HTTPError, urllib.error.URLError) as error:
        raise SignedReleaseInstallError(f"could not download {label}: {error}") from error
    return bytes(result)


def _load_location(
    *, source: Optional[Path], url: Optional[str], maximum: int, label: str
) -> bytes:
    if (source is None) == (url is None):
        raise SignedReleaseInstallError(f"choose exactly one local or HTTPS {label}")
    if source is not None:
        return _read_local_bounded(source, maximum, label)
    assert url is not None
    return _download_bounded(url, maximum, label)


def _exact_object(value: Any, keys: frozenset[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise SignedReleaseInstallError(f"{label} has unexpected or missing fields")
    return value


def _positive_integer(value: Any, label: str, maximum: int = 10_000_000) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not (1 <= value <= maximum):
        raise SignedReleaseInstallError(f"{label} must be a bounded positive integer")
    return value


def validate_manifest(payload: bytes, *, current_app_build: int) -> dict[str, Any]:
    try:
        decoded = payload.decode("utf-8")
        raw = json.loads(decoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SignedReleaseInstallError(f"release manifest is not valid UTF-8 JSON: {error}") from error
    if _canonical_json(raw) != payload:
        raise SignedReleaseInstallError("release manifest is not byte-canonical JSON")
    root = _exact_object(raw, ROOT_KEYS, "release manifest")
    if root["manifestVersion"] != MANIFEST_VERSION:
        raise SignedReleaseInstallError("release manifest version is unsupported")
    _positive_integer(current_app_build, "current app build", 2_147_483_647)
    minimum_app_build = _positive_integer(
        root["minimumAppBuild"], "minimum app build", 2_147_483_647
    )
    if minimum_app_build > current_app_build:
        raise SignedReleaseInstallError(
            "release requires a newer app build "
            f"({minimum_app_build}; current build is {current_app_build})"
        )
    if (
        not isinstance(root["contentVersion"], str)
        or not root["contentVersion"].strip()
        or len(root["contentVersion"]) > 256
        or "\x00" in root["contentVersion"]
    ):
        raise SignedReleaseInstallError("release contentVersion is empty")
    for key in ("fixtureSHA256", "logicalContentDigest", "targetManifestSHA256"):
        if not isinstance(root[key], str) or SHA256_PATTERN.fullmatch(root[key]) is None:
            raise SignedReleaseInstallError(f"release {key} is not a SHA-256")
    if (
        not isinstance(root["releaseAttestationID"], str)
        or ATTESTATION_PATTERN.fullmatch(root["releaseAttestationID"]) is None
    ):
        raise SignedReleaseInstallError("release attestation identity is invalid")
    created_at = root["createdAt"]
    if not isinstance(created_at, str) or CREATED_AT_PATTERN.fullmatch(created_at) is None:
        raise SignedReleaseInstallError(
            "release createdAt must be a canonical whole-second UTC timestamp"
        )
    try:
        dt.datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise SignedReleaseInstallError("release createdAt is not a real timestamp") from error

    release_sequence = _positive_integer(
        root["releaseSequence"], "release sequence", 9_223_372_036_854_775_807
    )
    rollback = root["rollbackAuthorization"]
    if rollback is not None:
        rollback = _exact_object(rollback, ROLLBACK_KEYS, "rollback authorization")
        source_sequence = _positive_integer(
            rollback["fromReleaseSequence"],
            "rollback source release sequence",
            9_223_372_036_854_775_807,
        )
        if source_sequence <= release_sequence:
            raise SignedReleaseInstallError(
                "rollback authorization must name a newer source release sequence"
            )
        if (
            not isinstance(rollback["reasonCode"], str)
            or ROLLBACK_REASON_PATTERN.fullmatch(rollback["reasonCode"]) is None
        ):
            raise SignedReleaseInstallError("rollback reason code is invalid")

    contracts = _exact_object(root["contracts"], CONTRACT_KEYS, "release contracts")
    for key in CONTRACT_KEYS:
        _positive_integer(contracts[key], f"release contract {key}")
    exact_contracts = {
        "lessonContractVersion": install_content_pack.LESSON_CONTRACT_VERSION,
        "normalizationVersion": install_content_pack.NORMALIZATION_VERSION,
        "resolverContractVersion": install_content_pack.RESOLVER_CONTRACT_VERSION,
        "schemaVersion": install_content_pack.SCHEMA_VERSION,
        "usageSelectionPolicyVersion": (
            install_content_pack.USAGE_SELECTION_POLICY_VERSION
        ),
    }
    for key, expected in exact_contracts.items():
        if contracts[key] != expected:
            raise SignedReleaseInstallError(
                f"release contract {key} is incompatible with this app"
            )
    if contracts["validatorVersion"] < install_content_pack.MINIMUM_VALIDATOR_VERSION:
        raise SignedReleaseInstallError("release validator contract is too old")
    if contracts["reviewPolicyVersion"] < install_content_pack.MINIMUM_REVIEW_POLICY_VERSION:
        raise SignedReleaseInstallError("release review policy is too old")

    locales = root["locales"]
    if (
        not isinstance(locales, list)
        or not locales
        or any(
            not isinstance(locale, str) or LOCALE_PATTERN.fullmatch(locale) is None
            for locale in locales
        )
        or locales != sorted(set(locales))
        or tuple(locales) != install_content_pack.SUPPORTED_CONTENT_LOCALES
    ):
        raise SignedReleaseInstallError(
            "release locales must be a nonempty sorted array of unique language tags"
        )

    counts = _exact_object(root["counts"], COUNT_KEYS, "release counts")
    entries = _positive_integer(counts["entries"], "entry count")
    usages = _positive_integer(counts["usages"], "Usage count", 20_000_000)
    explanations = _positive_integer(
        counts["explanations"], "explanation count", 20_000_000
    )
    if usages < entries or explanations != usages:
        raise SignedReleaseInstallError("release counts do not describe complete Entry coverage")

    signature = _exact_object(root["signature"], SIGNATURE_KEYS, "release signature")
    if (
        signature["algorithm"] != "sshsig-ed25519"
        or signature["namespace"] != SIGNATURE_NAMESPACE
        or signature["fileName"] != "release-manifest.json.sig"
        or not isinstance(signature["identity"], str)
        or IDENTITY_PATTERN.fullmatch(signature["identity"]) is None
        or not isinstance(signature["keyID"], str)
        or KEY_ID_PATTERN.fullmatch(signature["keyID"]) is None
    ):
        raise SignedReleaseInstallError("release signature contract is invalid")

    artifact = _exact_object(root["artifact"], ARTIFACT_KEYS, "release artifact")
    if not isinstance(artifact["fileName"], str) or (
        not artifact["fileName"]
        or artifact["fileName"] in {".", ".."}
        or "/" in artifact["fileName"]
        or "\\" in artifact["fileName"]
    ):
        raise SignedReleaseInstallError("release artifact filename is invalid")
    if artifact["compression"] != "none":
        raise SignedReleaseInstallError("this app supports only uncompressed SQLite releases")
    for key in ("compressedSHA256", "uncompressedSHA256"):
        if not isinstance(artifact[key], str) or SHA256_PATTERN.fullmatch(artifact[key]) is None:
            raise SignedReleaseInstallError(f"release artifact {key} is invalid")
    compressed_size = _positive_integer(
        artifact["compressedSizeBytes"], "compressed artifact size", MAX_PACK_BYTES
    )
    uncompressed_size = _positive_integer(
        artifact["uncompressedSizeBytes"], "uncompressed artifact size", MAX_PACK_BYTES
    )
    if (
        artifact["compressedSHA256"] != artifact["uncompressedSHA256"]
        or compressed_size != uncompressed_size
    ):
        raise SignedReleaseInstallError(
            "an uncompressed release must use identical artifact hashes and sizes"
        )
    if not isinstance(artifact["downloadURL"], str):
        raise SignedReleaseInstallError("release artifact URL is invalid")
    url = install_content_pack.validate_https_url(artifact["downloadURL"])
    parsed_url = urlsplit(url)
    if parsed_url.query or parsed_url.fragment:
        raise SignedReleaseInstallError(
            "release artifact URL must not contain a query or fragment"
        )
    path_name = unquote(parsed_url.path.rsplit("/", 1)[-1])
    if path_name != artifact["fileName"]:
        raise SignedReleaseInstallError("artifact URL filename does not match the manifest")
    return root


def _trusted_ed25519_lines(
    *, allowed_signers: Path, identity: str, expected_key_id: str
) -> list[str]:
    allowed_signers = allowed_signers.expanduser().resolve()
    if not allowed_signers.is_file():
        raise SignedReleaseInstallError(
            f"allowed-signers trust file does not exist: {allowed_signers}"
        )
    try:
        if allowed_signers.stat().st_size > 1024 * 1024:
            raise SignedReleaseInstallError("allowed-signers trust file is unexpectedly large")
        trust_lines = allowed_signers.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise SignedReleaseInstallError(
            f"could not read allowed-signers trust file: {error}"
        ) from error
    matching_identity = False
    selected: list[str] = []
    for line in trust_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if not fields or identity not in fields[0].split(","):
            continue
        matching_identity = True
        key_index = next(
            (
                index
                for index, field in enumerate(fields[1:], start=1)
                if field.startswith(("ssh-", "sk-ssh-"))
            ),
            -1,
        )
        if key_index < 0 or key_index + 1 >= len(fields):
            raise SignedReleaseInstallError(
                "the release identity has a malformed allowed-signers entry"
            )
        if fields[key_index] != "ssh-ed25519":
            raise SignedReleaseInstallError(
                "the release identity must map only to ssh-ed25519 keys in allowed-signers"
            )
        try:
            public_blob = base64.b64decode(fields[key_index + 1], validate=True)
        except (ValueError, binascii.Error) as error:
            raise SignedReleaseInstallError(
                "the release identity has an invalid Ed25519 public key"
            ) from error
        key_id = "ssh-ed25519-sha256:" + hashlib.sha256(public_blob).hexdigest()
        if key_id == expected_key_id:
            selected.append(stripped)
    if not matching_identity:
        raise SignedReleaseInstallError(
            "the release identity is absent from the allowed-signers trust root"
        )
    if not selected:
        raise SignedReleaseInstallError(
            "the manifest signing keyID is not trusted for the release identity"
        )
    return selected


def verify_signature(
    *,
    payload: bytes,
    signature: bytes,
    allowed_signers: Path,
    identity: str,
    key_id: str,
) -> None:
    selected_trust_lines = _trusted_ed25519_lines(
        allowed_signers=allowed_signers,
        identity=identity,
        expected_key_id=key_id,
    )
    with tempfile.TemporaryDirectory(prefix="wordbook-release-signature-") as directory:
        signature_path = Path(directory) / "release-manifest.json.sig"
        signature_path.write_bytes(signature)
        exact_allowed_signers = Path(directory) / "allowed_signers"
        exact_allowed_signers.write_text(
            "\n".join(selected_trust_lines) + "\n", encoding="utf-8"
        )
        try:
            result = subprocess.run(
                [
                    "ssh-keygen",
                    "-Y",
                    "verify",
                    "-f",
                    str(exact_allowed_signers),
                    "-I",
                    identity,
                    "-n",
                    SIGNATURE_NAMESPACE,
                    "-s",
                    str(signature_path),
                ],
                input=payload,
                check=False,
                capture_output=True,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise SignedReleaseInstallError(f"could not invoke ssh-keygen: {error}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).decode("utf-8", "replace").strip()
        raise SignedReleaseInstallError(
            "release manifest signature is not trusted: " + (detail or "verification failed")
        )


def _default_state_path(destination: Path) -> Path:
    return destination.with_name(f".{destination.stem}-release-state.json")


def _default_previous_good_path(destination: Path) -> Path:
    return destination.with_name(f".{destination.stem}.previous{destination.suffix}")


def _default_pending_path(state_path: Path) -> Path:
    return state_path.with_name(state_path.name + ".pending")


def _default_build_receipt_path(destination: Path) -> Path:
    return destination.with_name(f".{destination.stem}-build-receipt.json")


def _manifest_sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _load_state(path: Path) -> Optional[dict[str, Any]]:
    if not path.exists():
        return None
    payload = _read_local_bounded(path, 64 * 1024, "content release state")
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SignedReleaseInstallError(
            f"content release state is not valid UTF-8 JSON: {error}"
        ) from error
    if _canonical_json(decoded) != payload:
        raise SignedReleaseInstallError("content release state is not byte-canonical JSON")
    state = _exact_object(decoded, STATE_KEYS, "content release state")
    if state["stateVersion"] != STATE_VERSION:
        raise SignedReleaseInstallError("content release state version is unsupported")
    _positive_integer(
        state["releaseSequence"], "installed release sequence", 9_223_372_036_854_775_807
    )
    highest_sequence = _positive_integer(
        state["highestAcceptedReleaseSequence"],
        "highest accepted release sequence",
        9_223_372_036_854_775_807,
    )
    if highest_sequence < state["releaseSequence"]:
        raise SignedReleaseInstallError(
            "highest accepted release sequence is older than the active release"
        )
    if not isinstance(state["contentVersion"], str) or not state["contentVersion"].strip():
        raise SignedReleaseInstallError("installed contentVersion is invalid")
    for key in ("artifactSHA256", "manifestSHA256"):
        if not isinstance(state[key], str) or SHA256_PATTERN.fullmatch(state[key]) is None:
            raise SignedReleaseInstallError(f"installed {key} is invalid")
    if not isinstance(state["keyID"], str) or KEY_ID_PATTERN.fullmatch(state["keyID"]) is None:
        raise SignedReleaseInstallError("installed signing keyID is invalid")
    return state


def _load_pending(path: Path) -> Optional[dict[str, Any]]:
    if not path.exists():
        return None
    payload = _read_local_bounded(path, 64 * 1024, "content activation receipt")
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SignedReleaseInstallError(
            f"content activation receipt is not valid UTF-8 JSON: {error}"
        ) from error
    if _canonical_json(decoded) != payload:
        raise SignedReleaseInstallError(
            "content activation receipt is not byte-canonical JSON"
        )
    pending = _exact_object(decoded, PENDING_KEYS, "content activation receipt")
    if pending["pendingVersion"] != 1:
        raise SignedReleaseInstallError("content activation receipt version is unsupported")
    for key in ("targetArtifactSHA256", "targetManifestSHA256"):
        if not isinstance(pending[key], str) or SHA256_PATTERN.fullmatch(pending[key]) is None:
            raise SignedReleaseInstallError(f"content activation receipt {key} is invalid")
    previous_digest = pending["previousArtifactSHA256"]
    if previous_digest is not None and (
        not isinstance(previous_digest, str)
        or SHA256_PATTERN.fullmatch(previous_digest) is None
    ):
        raise SignedReleaseInstallError(
            "content activation receipt previousArtifactSHA256 is invalid"
        )
    _positive_integer(
        pending["targetReleaseSequence"],
        "activation target release sequence",
        9_223_372_036_854_775_807,
    )
    return pending


def _state_for_manifest(
    manifest: Mapping[str, Any],
    payload: bytes,
    previous_state: Optional[Mapping[str, Any]],
) -> dict[str, Any]:
    highest_sequence = int(manifest["releaseSequence"])
    if previous_state is not None:
        highest_sequence = max(
            highest_sequence, int(previous_state["highestAcceptedReleaseSequence"])
        )
    return {
        "artifactSHA256": manifest["artifact"]["uncompressedSHA256"],
        "contentVersion": manifest["contentVersion"],
        "highestAcceptedReleaseSequence": highest_sequence,
        "keyID": manifest["signature"]["keyID"],
        "manifestSHA256": _manifest_sha256(payload),
        "releaseSequence": manifest["releaseSequence"],
        "stateVersion": STATE_VERSION,
    }


def _build_receipt_for_manifest(
    manifest: Mapping[str, Any], payload: bytes
) -> dict[str, Any]:
    receipt = {
        "artifactSHA256": manifest["artifact"]["uncompressedSHA256"],
        "artifactSizeBytes": manifest["artifact"]["uncompressedSizeBytes"],
        "buildReceiptVersion": BUILD_RECEIPT_VERSION,
        "contentVersion": manifest["contentVersion"],
        "contracts": dict(manifest["contracts"]),
        "counts": dict(manifest["counts"]),
        "fixtureSHA256": manifest["fixtureSHA256"],
        "logicalContentDigest": manifest["logicalContentDigest"],
        "manifestSHA256": _manifest_sha256(payload),
        "minimumAppBuild": manifest["minimumAppBuild"],
        "releaseSequence": manifest["releaseSequence"],
        "signatureKeyID": manifest["signature"]["keyID"],
    }
    if set(receipt) != BUILD_RECEIPT_KEYS:
        raise SignedReleaseInstallError("internal build-receipt contract mismatch")
    return receipt


def _write_atomic(path: Path, payload: bytes, *, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        install_content_pack.fsync_directory(path.parent)
    except OSError as error:
        raise SignedReleaseInstallError(f"could not atomically write {path}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _preserve_previous_good(source: Path, destination: Path) -> None:
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
        )
    except OSError as error:
        raise SignedReleaseInstallError(
            f"could not stage previous-good content pack: {error}"
        ) from error
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        install_content_pack.copy_local_source(source, temporary)
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
        install_content_pack.fsync_directory(destination.parent)
    except OSError as error:
        raise SignedReleaseInstallError(
            f"could not preserve previous-good content pack: {error}"
        ) from error
    finally:
        temporary.unlink(missing_ok=True)


def _validate_pack_against_manifest(
    summary: Mapping[str, Any], manifest: Mapping[str, Any]
) -> None:
    contracts = manifest["contracts"]
    expected = {
        "contentVersion": manifest["contentVersion"],
        "entries": manifest["counts"]["entries"],
        "explanations": manifest["counts"]["explanations"],
        "fixtureSHA256": manifest["fixtureSHA256"],
        "lessonContractVersion": contracts["lessonContractVersion"],
        "locales": manifest["locales"],
        "logicalContentDigest": manifest["logicalContentDigest"],
        "normalizationVersion": contracts["normalizationVersion"],
        "resolverContractVersion": contracts["resolverContractVersion"],
        "reviewPolicyVersion": contracts["reviewPolicyVersion"],
        "schemaVersion": contracts["schemaVersion"],
        "usageSelectionPolicyVersion": contracts["usageSelectionPolicyVersion"],
        "usages": manifest["counts"]["usages"],
        "validatorVersion": contracts["validatorVersion"],
    }
    mismatches = [key for key, value in expected.items() if summary.get(key) != value]
    if mismatches:
        raise SignedReleaseInstallError(
            "signed manifest does not describe the verified SQLite pack: "
            + ", ".join(sorted(mismatches))
        )


def _remove_durable(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
        install_content_pack.fsync_directory(path.parent)
    except OSError as error:
        raise SignedReleaseInstallError(f"could not remove {path}: {error}") from error


def _reconcile_pending_activation(
    *,
    pending_path: Path,
    pending: Optional[Mapping[str, Any]],
    destination: Path,
    state_path: Path,
    current_state: Optional[Mapping[str, Any]],
    manifest: Mapping[str, Any],
    manifest_payload: bytes,
) -> Optional[dict[str, Any]]:
    if pending is None:
        return None if current_state is None else dict(current_state)
    manifest_digest = _manifest_sha256(manifest_payload)
    if (
        pending["targetManifestSHA256"] != manifest_digest
        or pending["targetArtifactSHA256"]
            != manifest["artifact"]["uncompressedSHA256"]
        or pending["targetReleaseSequence"] != manifest["releaseSequence"]
    ):
        raise SignedReleaseInstallError(
            "an unfinished content activation belongs to a different signed release"
        )
    destination_digest = (
        install_content_pack.sha256_file(destination) if destination.is_file() else None
    )
    if destination_digest == pending["targetArtifactSHA256"]:
        summary = install_content_pack.validate_content_pack(destination)
        _validate_pack_against_manifest(summary, manifest)
        state = _state_for_manifest(manifest, manifest_payload, current_state)
        _write_atomic(state_path, _canonical_json(state), mode=0o644)
        _remove_durable(pending_path)
        return state
    if destination_digest == pending["previousArtifactSHA256"]:
        _remove_durable(pending_path)
        return None if current_state is None else dict(current_state)
    raise SignedReleaseInstallError(
        "active content matches neither side of the unfinished activation"
    )


def _validate_release_transition(
    *,
    manifest: Mapping[str, Any],
    manifest_payload: bytes,
    current_state: Optional[Mapping[str, Any]],
    rollback_key_ids: frozenset[str],
) -> None:
    for key_id in rollback_key_ids:
        if KEY_ID_PATTERN.fullmatch(key_id) is None:
            raise SignedReleaseInstallError(f"configured rollback keyID is invalid: {key_id}")
    if current_state is None:
        if manifest["rollbackAuthorization"] is not None:
            raise SignedReleaseInstallError(
                "rollback authorization is not valid for a fresh installation"
            )
        return
    current_sequence = int(current_state["releaseSequence"])
    highest_sequence = int(current_state["highestAcceptedReleaseSequence"])
    target_sequence = int(manifest["releaseSequence"])
    if target_sequence == current_sequence:
        if current_state["manifestSHA256"] != _manifest_sha256(manifest_payload):
            raise SignedReleaseInstallError(
                "release sequence is already installed with a different signed manifest"
            )
        return
    if target_sequence > current_sequence:
        if manifest["rollbackAuthorization"] is not None:
            raise SignedReleaseInstallError(
                "rollback authorization is only valid for an actual downgrade"
            )
        if target_sequence <= highest_sequence:
            raise SignedReleaseInstallError(
                "a previously superseded release sequence cannot be replayed"
            )
        return
    rollback = manifest["rollbackAuthorization"]
    if (
        rollback is None
        or rollback["fromReleaseSequence"] != current_sequence
        or manifest["signature"]["keyID"] not in rollback_key_ids
    ):
        raise SignedReleaseInstallError(
            "release downgrade is not authorized for the currently installed sequence"
        )


def _validate_active_state_binding(
    *, destination: Path, current_state: Optional[Mapping[str, Any]]
) -> None:
    if current_state is None:
        return
    if not destination.is_file():
        raise SignedReleaseInstallError(
            "release state exists but the active content pack is missing"
        )
    actual_digest = install_content_pack.sha256_file(destination)
    if actual_digest != current_state["artifactSHA256"]:
        raise SignedReleaseInstallError(
            "active content pack does not match the installed release state"
        )
    summary = install_content_pack.validate_content_pack(destination)
    if summary["contentVersion"] != current_state["contentVersion"]:
        raise SignedReleaseInstallError(
            "active content version does not match the installed release state"
        )


def install_signed_release(
    *,
    destination: Path,
    allowed_signers: Path,
    current_app_build: int,
    manifest_source: Optional[Path] = None,
    manifest_url: Optional[str] = None,
    signature_source: Optional[Path] = None,
    signature_url: Optional[str] = None,
    state_path: Optional[Path] = None,
    pending_path: Optional[Path] = None,
    previous_good_path: Optional[Path] = None,
    build_receipt_path: Optional[Path] = None,
    rollback_key_ids: frozenset[str] = frozenset(),
) -> dict[str, Any]:
    manifest_payload = _load_location(
        source=manifest_source,
        url=manifest_url,
        maximum=MAX_MANIFEST_BYTES,
        label="release manifest",
    )
    signature_payload = _load_location(
        source=signature_source,
        url=signature_url,
        maximum=MAX_SIGNATURE_BYTES,
        label="release signature",
    )
    manifest = validate_manifest(
        manifest_payload, current_app_build=current_app_build
    )
    verify_signature(
        payload=manifest_payload,
        signature=signature_payload,
        allowed_signers=allowed_signers,
        identity=manifest["signature"]["identity"],
        key_id=manifest["signature"]["keyID"],
    )
    destination = destination.expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        install_content_pack.reject_sqlite_sidecars(destination)
    except install_content_pack.ContentPackInstallError as error:
        raise SignedReleaseInstallError(str(error)) from error
    state_path = (
        _default_state_path(destination)
        if state_path is None
        else state_path.expanduser().resolve()
    )
    previous_good_path = (
        _default_previous_good_path(destination)
        if previous_good_path is None
        else previous_good_path.expanduser().resolve()
    )
    pending_path = (
        _default_pending_path(state_path)
        if pending_path is None
        else pending_path.expanduser().resolve()
    )
    build_receipt_path = (
        _default_build_receipt_path(destination)
        if build_receipt_path is None
        else build_receipt_path.expanduser().resolve()
    )
    if len(
        {
            destination,
            state_path,
            pending_path,
            previous_good_path,
            build_receipt_path,
        }
    ) != 5:
        raise SignedReleaseInstallError(
            "destination, release state, activation receipt, build receipt, and "
            "previous-good paths must differ"
        )
    current_state = _load_state(state_path)
    _validate_release_transition(
        manifest=manifest,
        manifest_payload=manifest_payload,
        current_state=current_state,
        rollback_key_ids=rollback_key_ids,
    )
    current_state = _reconcile_pending_activation(
        pending_path=pending_path,
        pending=_load_pending(pending_path),
        destination=destination,
        state_path=state_path,
        current_state=current_state,
        manifest=manifest,
        manifest_payload=manifest_payload,
    )
    _validate_active_state_binding(
        destination=destination,
        current_state=current_state,
    )
    _validate_release_transition(
        manifest=manifest,
        manifest_payload=manifest_payload,
        current_state=current_state,
        rollback_key_ids=rollback_key_ids,
    )
    artifact = manifest["artifact"]
    expected_digest = artifact["uncompressedSHA256"]
    expected_size = artifact["uncompressedSizeBytes"]
    if (
        destination.is_file()
        and destination.stat().st_size == expected_size
        and install_content_pack.sha256_file(destination) == expected_digest
    ):
        summary = install_content_pack.validate_content_pack(destination)
        _validate_pack_against_manifest(summary, manifest)
        _write_atomic(
            state_path,
            _canonical_json(
                _state_for_manifest(manifest, manifest_payload, current_state)
            ),
            mode=0o644,
        )
        _write_atomic(
            build_receipt_path,
            _canonical_json(
                _build_receipt_for_manifest(manifest, manifest_payload)
            ),
            mode=0o644,
        )
        return manifest

    with tempfile.TemporaryDirectory(
        prefix=f".{destination.name}.verified-", dir=destination.parent
    ) as directory:
        verified_pack = Path(directory) / artifact["fileName"]
        install_content_pack.install_content_pack(
            destination=verified_pack,
            expected_sha256=expected_digest,
            url=artifact["downloadURL"],
            expected_size=expected_size,
        )
        summary = install_content_pack.validate_content_pack(verified_pack)
        _validate_pack_against_manifest(summary, manifest)

        install_content_pack.reject_sqlite_sidecars(destination)
        previous_digest = (
            install_content_pack.sha256_file(destination)
            if destination.is_file()
            else None
        )
        if destination.is_file():
            try:
                install_content_pack.validate_content_pack(destination)
            except install_content_pack.ContentPackInstallError:
                pass
            else:
                _preserve_previous_good(destination, previous_good_path)
        pending = {
            "pendingVersion": 1,
            "previousArtifactSHA256": previous_digest,
            "targetArtifactSHA256": expected_digest,
            "targetManifestSHA256": _manifest_sha256(manifest_payload),
            "targetReleaseSequence": manifest["releaseSequence"],
        }
        _write_atomic(pending_path, _canonical_json(pending), mode=0o644)
        try:
            os.chmod(verified_pack, 0o644)
            os.replace(verified_pack, destination)
            install_content_pack.fsync_directory(destination.parent)
        except OSError as error:
            raise SignedReleaseInstallError(
                f"could not activate the verified content pack: {error}"
            ) from error

    _write_atomic(
        state_path,
        _canonical_json(_state_for_manifest(manifest, manifest_payload, current_state)),
        mode=0o644,
    )
    _remove_durable(pending_path)
    _write_atomic(
        build_receipt_path,
        _canonical_json(_build_receipt_for_manifest(manifest, manifest_payload)),
        mode=0o644,
    )
    return manifest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    manifest = parser.add_mutually_exclusive_group()
    manifest.add_argument("--manifest-source", type=Path)
    manifest.add_argument("--manifest-url")
    signature = parser.add_mutually_exclusive_group()
    signature.add_argument("--signature-source", type=Path)
    signature.add_argument("--signature-url")
    parser.add_argument("--allowed-signers", type=Path)
    parser.add_argument(
        "--app-build",
        type=int,
        help=f"current client build number (or set {APP_BUILD_ENV})",
    )
    parser.add_argument(
        "--rollback-key-id",
        action="append",
        default=[],
        help=(
            "independently trusted Ed25519 keyID allowed to authorize a downgrade; "
            "repeat for key rotation"
        ),
    )
    parser.add_argument(
        "--destination",
        type=Path,
        default=install_content_pack.CONTENT_PACK_PATH,
        help="destination SQLite path (defaults to the bundled client resource)",
    )
    parser.add_argument("--state-path", type=Path)
    parser.add_argument("--pending-path", type=Path)
    parser.add_argument("--previous-good-path", type=Path)
    parser.add_argument(
        "--build-receipt-path",
        type=Path,
        help=(
            "durable Release-build receipt path "
            f"(or set {BUILD_RECEIPT_PATH_ENV})"
        ),
    )
    return parser


def main(argv: Optional[Sequence[str]] = None, environment: Optional[Mapping[str, str]] = None) -> int:
    args = build_parser().parse_args(argv)
    values = os.environ if environment is None else environment
    manifest_url = args.manifest_url or (
        None if args.manifest_source is not None else values.get(MANIFEST_URL_ENV)
    )
    signature_url = args.signature_url or (
        None if args.signature_source is not None else values.get(SIGNATURE_URL_ENV)
    )
    allowed_signers = args.allowed_signers or (
        Path(values[ALLOWED_SIGNERS_ENV]) if values.get(ALLOWED_SIGNERS_ENV) else None
    )
    if allowed_signers is None:
        raise SignedReleaseInstallError(
            f"pass --allowed-signers or set {ALLOWED_SIGNERS_ENV}"
        )
    raw_app_build: object = args.app_build
    if raw_app_build is None:
        raw_app_build = values.get(APP_BUILD_ENV)
    try:
        app_build = int(raw_app_build)  # type: ignore[arg-type]
    except (TypeError, ValueError) as error:
        raise SignedReleaseInstallError(
            f"pass --app-build or set {APP_BUILD_ENV} to a positive integer"
        ) from error
    environment_rollback_keys = {
        value.strip()
        for value in values.get(ROLLBACK_KEY_IDS_ENV, "").split(",")
        if value.strip()
    }
    rollback_key_ids = frozenset(args.rollback_key_id) | environment_rollback_keys
    build_receipt_path = args.build_receipt_path or (
        Path(values[BUILD_RECEIPT_PATH_ENV])
        if values.get(BUILD_RECEIPT_PATH_ENV)
        else None
    )
    manifest = install_signed_release(
        destination=args.destination,
        allowed_signers=allowed_signers,
        current_app_build=app_build,
        manifest_source=args.manifest_source,
        manifest_url=manifest_url,
        signature_source=args.signature_source,
        signature_url=signature_url,
        state_path=args.state_path,
        pending_path=args.pending_path,
        previous_good_path=args.previous_good_path,
        build_receipt_path=build_receipt_path,
        rollback_key_ids=frozenset(rollback_key_ids),
    )
    print(f"Signed Wordbook content release is ready: {args.destination}")
    print(f"Content version: {manifest['contentVersion']}")
    print(f"SHA-256: {manifest['artifact']['uncompressedSHA256']}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (
        SignedReleaseInstallError,
        install_content_pack.ContentPackInstallError,
    ) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
