#!/usr/bin/env python3
"""Prepare Wordbook's pinned, text-only Qwen model using the Python stdlib."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import time
from typing import BinaryIO, Iterable
import urllib.error
import urllib.request


REVISION = "674aaa7240b91e8012fcad5d791b7dfe5ba90207"
SOURCE_URL = (
    "https://huggingface.co/mlx-community/Qwen3.5-2B-4bit/resolve/"
    f"{REVISION}/model.safetensors"
)
EXPECTED_SIZE = 1_059_405_152
EXPECTED_SHA256 = "b93b36a825ff36ef68eb4249295ac24942e15d67794e9747961e1640fe8a9b39"
EXPECTED_LANGUAGE_TENSORS = 694
EXPECTED_VISION_TENSORS = 297
EXPECTED_PAYLOAD_SIZE = 1_059_315_904
EXPECTED_OUTPUT_HEADER_SIZE = 89_240
CHUNK_SIZE = 4 * 1024 * 1024
USER_AGENT = "Wordbook-local-model-setup/1"

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = REPOSITORY_ROOT / "LocalModels/Qwen3.5-2B-4bit-text/model.safetensors"


class SetupError(RuntimeError):
    pass


class RangeUnavailable(SetupError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(CHUNK_SIZE):
            digest.update(chunk)
    return digest.hexdigest()


def valid_model(path: Path, *, report: bool = False) -> bool:
    if not path.is_file() or path.is_symlink():
        return False
    size = path.stat().st_size
    if size != EXPECTED_SIZE:
        if report:
            print(f"Existing model has the wrong size: {size} (expected {EXPECTED_SIZE}).")
        return False
    digest = sha256_file(path)
    if digest != EXPECTED_SHA256:
        if report:
            print(f"Existing model has the wrong SHA-256: {digest}.")
        return False
    return True


def read_exact(stream: BinaryIO, count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = count
    while remaining:
        chunk = stream.read(min(CHUNK_SIZE, remaining))
        if not chunk:
            raise SetupError(f"Download ended {remaining} bytes early.")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def discard_exact(stream: BinaryIO, count: int) -> None:
    remaining = count
    while remaining:
        chunk = stream.read(min(CHUNK_SIZE, remaining))
        if not chunk:
            raise SetupError(f"Download ended {remaining} bytes early.")
        remaining -= len(chunk)


def open_request(request: urllib.request.Request):
    last_error: Exception | None = None
    for attempt in range(4):
        try:
            return urllib.request.urlopen(request, timeout=120)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            last_error = error
            if attempt == 3:
                break
            time.sleep(2**attempt)
    raise SetupError(f"Could not download the pinned model: {last_error}") from last_error


def open_range(start: int, end: int, expected_total: int | None = None):
    request = urllib.request.Request(
        SOURCE_URL,
        headers={
            "Range": f"bytes={start}-{end}",
            "Accept-Encoding": "identity",
            "User-Agent": USER_AGENT,
        },
    )
    response = open_request(request)
    status = response.getcode()
    if status == 200:
        response.close()
        raise RangeUnavailable("The download server ignored HTTP Range.")
    if status != 206:
        response.close()
        raise SetupError(f"Unexpected HTTP status for a range request: {status}.")

    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
    if not match:
        response.close()
        raise SetupError("The range response has no valid Content-Range header.")
    actual_start, actual_end, total = map(int, match.groups())
    if (actual_start, actual_end) != (start, end):
        response.close()
        raise SetupError(f"The server returned bytes {actual_start}-{actual_end}, not {start}-{end}.")
    if expected_total is not None and total != expected_total:
        response.close()
        raise SetupError("The source file changed between range requests.")
    content_length = response.headers.get("Content-Length")
    if content_length is not None and int(content_length) != end - start + 1:
        response.close()
        raise SetupError("The range response has an unexpected length.")
    return response, total


def fetch_range(start: int, end: int, expected_total: int | None = None) -> tuple[bytes, int]:
    response, total = open_range(start, end, expected_total)
    with response:
        return read_exact(response, end - start + 1), total


def parse_source_header(raw: bytes, source_total: int | None):
    try:
        source = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SetupError("The pinned source has an invalid safetensors header.") from error
    if not isinstance(source, dict) or source.get("__metadata__") != {"format": "mlx"}:
        raise SetupError("The pinned source has unexpected safetensors metadata.")

    language: list[dict[str, object]] = []
    vision_count = 0
    all_spans: list[tuple[int, int]] = []
    output_offset = 0
    output_header: dict[str, object] = {"__metadata__": source["__metadata__"]}

    for name, description in source.items():
        if name == "__metadata__":
            continue
        if not isinstance(description, dict):
            raise SetupError(f"Tensor {name!r} has invalid metadata.")
        offsets = description.get("data_offsets")
        dtype = description.get("dtype")
        shape = description.get("shape")
        if (
            not isinstance(offsets, list)
            or len(offsets) != 2
            or not all(isinstance(value, int) for value in offsets)
            or offsets[0] < 0
            or offsets[1] <= offsets[0]
            or not isinstance(dtype, str)
            or not isinstance(shape, list)
        ):
            raise SetupError(f"Tensor {name!r} has invalid metadata.")
        source_start, source_end = offsets
        all_spans.append((source_start, source_end))
        if name.startswith("vision_tower."):
            vision_count += 1
            continue
        if not name.startswith("language_model."):
            raise SetupError(f"Unexpected tensor namespace: {name!r}.")

        size = source_end - source_start
        output_header[name] = {
            "dtype": dtype,
            "shape": shape,
            "data_offsets": [output_offset, output_offset + size],
        }
        language.append(
            {
                "name": name,
                "source_start": source_start,
                "source_end": source_end,
                "output_start": output_offset,
            }
        )
        output_offset += size

    if len(language) != EXPECTED_LANGUAGE_TENSORS or vision_count != EXPECTED_VISION_TENSORS:
        raise SetupError(
            f"Unexpected tensor counts: {len(language)} language, {vision_count} vision."
        )
    if output_offset != EXPECTED_PAYLOAD_SIZE:
        raise SetupError(f"Unexpected language-model payload size: {output_offset}.")

    sorted_spans = sorted(all_spans)
    if not sorted_spans or sorted_spans[0][0] != 0:
        raise SetupError("The source tensor data does not begin at offset zero.")
    for previous, current in zip(sorted_spans, sorted_spans[1:]):
        if previous[1] != current[0]:
            raise SetupError("The source tensor data contains a gap or overlap.")
    source_payload_size = sorted_spans[-1][1]
    if source_total is not None and source_total != 8 + len(raw) + source_payload_size:
        raise SetupError("The source size does not match its safetensors header.")

    header_json = json.dumps(output_header, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    output_header_raw = header_json + b" " * (-len(header_json) % 8)
    if len(output_header_raw) != EXPECTED_OUTPUT_HEADER_SIZE:
        raise SetupError(f"Unexpected generated header size: {len(output_header_raw)}.")
    if 8 + len(output_header_raw) + output_offset != EXPECTED_SIZE:
        raise SetupError("The generated model size does not match the pinned manifest.")
    return language, source_payload_size, output_header_raw


def read_source_header_with_ranges():
    prefix, source_total = fetch_range(0, 7)
    header_size = struct.unpack("<Q", prefix)[0]
    if header_size <= 0 or header_size > 16 * 1024 * 1024:
        raise SetupError(f"Unreasonable safetensors header size: {header_size}.")
    raw, _ = fetch_range(8, 7 + header_size, source_total)
    return raw, source_total


def initialize_output(output: BinaryIO, header: bytes) -> None:
    output.seek(0)
    output.truncate(0)
    output.write(struct.pack("<Q", len(header)))
    output.write(header)
    output.truncate(EXPECTED_SIZE)


def copy_to_output(source: BinaryIO, output: BinaryIO, count: int, output_offset: int) -> None:
    output.seek(8 + EXPECTED_OUTPUT_HEADER_SIZE + output_offset)
    remaining = count
    while remaining:
        chunk = source.read(min(CHUNK_SIZE, remaining))
        if not chunk:
            raise SetupError(f"Download ended {remaining} bytes early.")
        output.write(chunk)
        remaining -= len(chunk)


def contiguous_groups(tensors: Iterable[dict[str, object]]):
    groups: list[list[dict[str, object]]] = []
    for tensor in sorted(tensors, key=lambda item: int(item["source_start"])):
        if groups and int(tensor["source_start"]) == int(groups[-1][-1]["source_end"]):
            groups[-1].append(tensor)
        else:
            groups.append([tensor])
    return groups


def populate_with_ranges(
    output: BinaryIO,
    tensors: list[dict[str, object]],
    source_data_start: int,
    source_total: int,
) -> None:
    groups = contiguous_groups(tensors)
    downloaded = 0
    next_report = 0
    for group in groups:
        first = int(group[0]["source_start"])
        last = int(group[-1]["source_end"])
        response, _ = open_range(source_data_start + first, source_data_start + last - 1, source_total)
        with response:
            for tensor in group:
                size = int(tensor["source_end"]) - int(tensor["source_start"])
                copy_to_output(response, output, size, int(tensor["output_start"]))
                downloaded += size
        percent = downloaded * 100 // EXPECTED_PAYLOAD_SIZE
        if percent >= next_report:
            print(f"Downloading text tensors: {percent}%")
            next_report = percent + 10


def populate_from_full_download(
    source: BinaryIO, output: BinaryIO, tensors: list[dict[str, object]]
) -> None:
    cursor = 0
    for tensor in sorted(tensors, key=lambda item: int(item["source_start"])):
        source_start = int(tensor["source_start"])
        source_end = int(tensor["source_end"])
        discard_exact(source, source_start - cursor)
        copy_to_output(source, output, source_end - source_start, int(tensor["output_start"]))
        cursor = source_end


def finalize(temp_path: Path, target: Path) -> None:
    size = temp_path.stat().st_size
    digest = sha256_file(temp_path)
    if size != EXPECTED_SIZE or digest != EXPECTED_SHA256:
        raise SetupError(
            "Generated model failed integrity verification: "
            f"size={size}, sha256={digest}."
        )
    os.chmod(temp_path, 0o644)
    os.replace(temp_path, target)
    try:
        directory = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError:
        pass


def make_temp(target: Path) -> tuple[BinaryIO, Path]:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = tempfile.NamedTemporaryFile(
        mode="w+b", prefix=".model.safetensors.", suffix=".tmp", dir=target.parent, delete=False
    )
    return temporary, Path(temporary.name)


def install_with_ranges(target: Path) -> None:
    raw_header, source_total = read_source_header_with_ranges()
    tensors, _, output_header = parse_source_header(raw_header, source_total)
    source_data_start = 8 + len(raw_header)
    temporary, temp_path = make_temp(target)
    try:
        with temporary as output:
            initialize_output(output, output_header)
            populate_with_ranges(output, tensors, source_data_start, source_total)
            output.flush()
            os.fsync(output.fileno())
        finalize(temp_path, target)
    finally:
        temp_path.unlink(missing_ok=True)


def install_with_full_download(target: Path) -> None:
    request = urllib.request.Request(
        SOURCE_URL, headers={"Accept-Encoding": "identity", "User-Agent": USER_AGENT}
    )
    response = open_request(request)
    temporary = None
    temp_path = None
    try:
        with response:
            prefix = read_exact(response, 8)
            header_size = struct.unpack("<Q", prefix)[0]
            if header_size <= 0 or header_size > 16 * 1024 * 1024:
                raise SetupError(f"Unreasonable safetensors header size: {header_size}.")
            raw_header = read_exact(response, header_size)
            content_length = response.headers.get("Content-Length")
            source_total = int(content_length) if content_length is not None else None
            tensors, _, output_header = parse_source_header(raw_header, source_total)
            temporary, temp_path = make_temp(target)
            with temporary as output:
                initialize_output(output, output_header)
                populate_from_full_download(response, output, tensors)
                output.flush()
                os.fsync(output.fileno())
        assert temp_path is not None
        finalize(temp_path, target)
    finally:
        if temporary is not None and not temporary.closed:
            temporary.close()
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify-only", action="store_true", help="verify the local model without downloading it"
    )
    arguments = parser.parse_args()

    if valid_model(MODEL_PATH, report=True):
        print(f"Local model is ready: {MODEL_PATH}")
        print(f"SHA-256: {EXPECTED_SHA256}")
        return 0
    if arguments.verify_only:
        print(f"Local model is missing or invalid: {MODEL_PATH}", file=sys.stderr)
        return 1
    if MODEL_PATH.is_symlink():
        raise SetupError(f"Refusing to replace symbolic link: {MODEL_PATH}")

    print(f"Preparing the pinned text-only model from Hugging Face revision {REVISION}.")
    print("HTTP Range is used so vision tensors are not downloaded when the server supports it.")
    try:
        install_with_ranges(MODEL_PATH)
    except RangeUnavailable:
        print("The server does not support HTTP Range; falling back to one streamed download.")
        install_with_full_download(MODEL_PATH)
    print(f"Local model is ready: {MODEL_PATH}")
    print(f"SHA-256: {EXPECTED_SHA256}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SetupError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
