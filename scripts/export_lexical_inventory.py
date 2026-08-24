#!/usr/bin/env python3
"""Export the shipped WBLI spelling inventories for content production.

Canonical spellings, the vocabulary-book union, and alias-only accepted input
surfaces remain separate.  The output does not assert that a spelling has a
selected Usage, source evidence, a teaching brief, or reviewed lesson content.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


MAGIC = b"WBLXIDX\0"
SUPPORTED_VERSION = 1
HEADER_SIZE = 88
HEADER_STRUCT = struct.Struct("<8s20I")


class InventoryError(ValueError):
    """Raised when a WBLI file is not safe to use as an inventory source."""


@dataclass(frozen=True)
class AliasOnlyStudySurface:
    surface: str
    runtime_primary_canonical_target: str
    study_canonical_targets: tuple[str, ...]
    canonical_target_count: int

    def document(self) -> dict[str, object]:
        return {
            "canonicalTargetCount": self.canonical_target_count,
            "runtimePrimaryCanonicalTarget": self.runtime_primary_canonical_target,
            "studyCanonicalTargets": list(self.study_canonical_targets),
            "surface": self.surface,
        }


@dataclass(frozen=True)
class LexicalInventory:
    canonical_spellings: tuple[str, ...]
    study_canonical_spellings: tuple[str, ...]
    alias_only_study_surfaces: tuple[AliasOnlyStudySurface, ...]
    book_tags: tuple[str, ...]
    source_alias_count: int
    source_book_count: int
    source_sha256: str
    payload_crc32: int
    format_version: int

    def document(self) -> dict[str, object]:
        return {
            "aliasOnlyStudySurfaces": {
                "kind": "aliasOnlySurfacesWithStudyCanonicalMappings",
                "mappings": [mapping.document() for mapping in self.alias_only_study_surfaces],
                "surfaceCount": len(self.alias_only_study_surfaces),
            },
            "canonicalEntries": {
                "kind": "allBundledCanonicalSpellings",
                "spellingCount": len(self.canonical_spellings),
                "spellings": list(self.canonical_spellings),
            },
            "inventoryKind": "bundledLexicalReleaseInventory",
            "schemaVersion": 2,
            "source": {
                "aliasCount": self.source_alias_count,
                "bookCount": self.source_book_count,
                "format": "WBLXIDX",
                "formatVersion": self.format_version,
                "payloadCRC32": f"{self.payload_crc32:08x}",
                "sha256": self.source_sha256,
                "wordCount": len(self.canonical_spellings),
            },
            "studyTargets": {
                "bookTags": list(self.book_tags),
                "kind": "canonicalUnionOfBundledVocabularyBooks",
                "spellingCount": len(self.study_canonical_spellings),
                "spellings": list(self.study_canonical_spellings),
            },
        }


def _unpack_u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise InventoryError("offset table extends beyond the file")
    return struct.unpack_from("<I", data, offset)[0]


def _checked_end(start: int, count: int, stride: int, file_size: int) -> int:
    if start < 0 or count < 0 or stride < 0:
        raise InventoryError("negative section bound")
    end = start + count * stride
    if end < start or end > file_size:
        raise InventoryError("section extends beyond the file")
    return end


def _read_offsets(
    data: bytes,
    table_offset: int,
    count: int,
    content_size: int,
    label: str,
) -> tuple[int, ...]:
    _checked_end(table_offset, count + 1, 4, len(data))
    offsets = tuple(_unpack_u32(data, table_offset + index * 4) for index in range(count + 1))
    if not offsets or offsets[0] != 0:
        raise InventoryError(f"{label} offset table must start at zero")
    if any(previous > current for previous, current in zip(offsets, offsets[1:])):
        raise InventoryError(f"{label} offsets are not monotonic")
    if offsets[-1] > content_size:
        raise InventoryError(f"{label} bytes extend beyond their section")
    return offsets


def _decode_strings(
    data: bytes,
    bytes_offset: int,
    offsets: Sequence[int],
    label: str,
    *,
    allow_empty: bool = False,
) -> tuple[str, ...]:
    result: list[str] = []
    for index, (start, end) in enumerate(zip(offsets, offsets[1:])):
        raw = data[bytes_offset + start : bytes_offset + end]
        try:
            value = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise InventoryError(f"{label} {index} is not valid UTF-8") from error
        if not value and not allow_empty:
            raise InventoryError(f"{label} {index} is empty")
        if "\x00" in value or "\n" in value or "\r" in value:
            raise InventoryError(f"{label} {index} contains a forbidden control character")
        result.append(value)
    return tuple(result)


def _fold_ascii(value: str) -> bytes:
    return bytes(byte + 32 if 65 <= byte <= 90 else byte for byte in value.encode("utf-8"))


def parse_lexical_index(data: bytes) -> LexicalInventory:
    """Validate a WBLI v1 container and return its exact canonical words."""

    if len(data) < HEADER_SIZE:
        raise InventoryError("file is shorter than the WBLI header")

    unpacked = HEADER_STRUCT.unpack_from(data)
    magic = unpacked[0]
    (
        version,
        header_size,
        declared_file_size,
        word_count,
        alias_count,
        alias_mapping_count,
        book_count,
        word_offsets_offset,
        word_bytes_offset,
        phrase_bits_offset,
        alias_string_offsets_offset,
        alias_bytes_offset,
        alias_target_offsets_offset,
        alias_targets_offset,
        book_records_offset,
        book_indices_offset,
        metadata_strings_offset,
        metadata_strings_size,
        payload_crc32,
        _format_flags,
    ) = unpacked[1:]

    if magic != MAGIC:
        raise InventoryError("invalid WBLI magic")
    if version != SUPPORTED_VERSION:
        raise InventoryError(f"unsupported WBLI version {version}")
    if header_size != HEADER_SIZE:
        raise InventoryError(f"unexpected WBLI header size {header_size}")
    if declared_file_size != len(data):
        raise InventoryError("declared file size does not match the source")

    word_offsets_end = _checked_end(word_offsets_offset, word_count + 1, 4, len(data))
    phrase_bits_end = _checked_end(phrase_bits_offset, (word_count + 7) // 8, 1, len(data))
    alias_string_offsets_end = _checked_end(
        alias_string_offsets_offset, alias_count + 1, 4, len(data)
    )
    alias_target_offsets_end = _checked_end(
        alias_target_offsets_offset, alias_count + 1, 4, len(data)
    )
    alias_targets_end = _checked_end(alias_targets_offset, alias_mapping_count, 4, len(data))
    book_records_end = _checked_end(book_records_offset, book_count, 16, len(data))
    metadata_strings_end = _checked_end(
        metadata_strings_offset, metadata_strings_size, 1, len(data)
    )

    if not (
        header_size <= word_offsets_offset
        and word_offsets_end <= word_bytes_offset
        and word_bytes_offset <= phrase_bits_offset
        and phrase_bits_end <= alias_string_offsets_offset
        and alias_string_offsets_end <= alias_bytes_offset
        and alias_bytes_offset <= alias_target_offsets_offset
        and alias_target_offsets_end <= alias_targets_offset
        and alias_targets_end <= book_records_offset
        and book_records_end <= book_indices_offset
        and book_indices_offset <= metadata_strings_offset
        and metadata_strings_end <= len(data)
        and (metadata_strings_offset - book_indices_offset) % 4 == 0
    ):
        raise InventoryError("WBLI sections overlap or are out of order")

    computed_crc32 = zlib.crc32(data[HEADER_SIZE:]) & 0xFFFF_FFFF
    if computed_crc32 != payload_crc32:
        raise InventoryError(
            f"payload CRC-32 mismatch: expected {payload_crc32:08x}, got {computed_crc32:08x}"
        )

    word_offsets = _read_offsets(
        data,
        word_offsets_offset,
        word_count,
        phrase_bits_offset - word_bytes_offset,
        "word",
    )
    alias_string_offsets = _read_offsets(
        data,
        alias_string_offsets_offset,
        alias_count,
        alias_target_offsets_offset - alias_bytes_offset,
        "alias string",
    )
    alias_target_offsets = _read_offsets(
        data,
        alias_target_offsets_offset,
        alias_count,
        alias_mapping_count,
        "alias target",
    )
    if alias_target_offsets[-1] != alias_mapping_count:
        raise InventoryError("alias mapping count does not match its offset table")

    spellings = _decode_strings(data, word_bytes_offset, word_offsets, "word")
    # The historical source contains one inert empty alias.  Runtime lookup
    # rejects an empty folded key, so preserving/validating the container does
    # not turn that alias into a canonical spelling.
    aliases = _decode_strings(
        data,
        alias_bytes_offset,
        alias_string_offsets,
        "alias",
        allow_empty=True,
    )

    if len(set(spellings)) != len(spellings):
        raise InventoryError("canonical word table contains an exact duplicate")
    folded = tuple(_fold_ascii(spelling) for spelling in spellings)
    if any(previous > current for previous, current in zip(folded, folded[1:])):
        raise InventoryError("canonical word table is not ASCII-case-folded sorted")

    folded_aliases = tuple(_fold_ascii(alias) for alias in aliases)
    if any(previous > current for previous, current in zip(folded_aliases, folded_aliases[1:])):
        raise InventoryError("alias table is not ASCII-case-folded sorted")
    if len(set(folded_aliases)) != len(folded_aliases):
        raise InventoryError("alias table contains a folded duplicate")

    alias_targets: list[int] = []
    for mapping_index in range(alias_mapping_count):
        target = _unpack_u32(data, alias_targets_offset + mapping_index * 4)
        if target >= word_count:
            raise InventoryError(f"alias target {mapping_index} is outside the word table")
        alias_targets.append(target)

    book_index_count = (metadata_strings_offset - book_indices_offset) // 4
    book_tags: list[str] = []
    study_word_indices: set[int] = set()
    for record_index in range(book_count):
        offset = book_records_offset + record_index * 16
        tag_start, tag_length, index_start, index_count = struct.unpack_from("<4I", data, offset)
        if tag_start + tag_length > metadata_strings_size:
            raise InventoryError(f"book record {record_index} has an invalid tag range")
        try:
            tag = data[
                metadata_strings_offset + tag_start : metadata_strings_offset + tag_start + tag_length
            ].decode("utf-8")
        except UnicodeDecodeError as error:
            raise InventoryError(f"book record {record_index} tag is not valid UTF-8") from error
        if not tag:
            raise InventoryError(f"book record {record_index} tag is empty")
        book_tags.append(tag)
        if index_start + index_count > book_index_count:
            raise InventoryError(f"book record {record_index} has an invalid word-index range")
        for index in range(index_start, index_start + index_count):
            study_word_indices.add(_unpack_u32(data, book_indices_offset + index * 4))

    for book_index in range(book_index_count):
        target = _unpack_u32(data, book_indices_offset + book_index * 4)
        if target >= word_count:
            raise InventoryError(f"book word index {book_index} is outside the word table")

    canonical_folded = set(folded)
    alias_only_study_surfaces: list[AliasOnlyStudySurface] = []
    for alias_index, surface in enumerate(aliases):
        # CompactLexicalIndex resolves a folded canonical spelling before it
        # consults the alias table.  Only otherwise non-empty surfaces are
        # truthfully "alias-only" accepted input.
        if not surface or folded_aliases[alias_index] in canonical_folded:
            continue
        target_start = alias_target_offsets[alias_index]
        target_end = alias_target_offsets[alias_index + 1]
        targets = alias_targets[target_start:target_end]
        study_targets = tuple(
            spellings[target] for target in targets if target in study_word_indices
        )
        if not study_targets:
            continue
        if not targets:
            raise InventoryError(f"alias {alias_index} has no canonical target")
        alias_only_study_surfaces.append(
            AliasOnlyStudySurface(
                surface=surface,
                runtime_primary_canonical_target=spellings[targets[0]],
                study_canonical_targets=study_targets,
                canonical_target_count=len(targets),
            )
        )

    return LexicalInventory(
        canonical_spellings=spellings,
        study_canonical_spellings=tuple(
            spelling
            for word_index, spelling in enumerate(spellings)
            if word_index in study_word_indices
        ),
        alias_only_study_surfaces=tuple(alias_only_study_surfaces),
        book_tags=tuple(book_tags),
        source_alias_count=alias_count,
        source_book_count=book_count,
        source_sha256=hashlib.sha256(data).hexdigest(),
        payload_crc32=payload_crc32,
        format_version=version,
    )


def serialize_inventory(inventory: LexicalInventory) -> bytes:
    """Return canonical, byte-stable UTF-8 JSON followed by one newline."""

    return (
        json.dumps(
            inventory.document(),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def export_inventory(source: Path) -> bytes:
    with source.open("rb") as handle:
        return serialize_inventory(parse_lexical_index(handle.read()))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Validate a WBLI v1 file and export its canonical spellings, "
            "vocabulary-book union, and alias-only study mappings. The export "
            "is a spelling inventory, not reviewed Usage or lesson coverage."
        )
    )
    parser.add_argument("source", type=Path, help="path to lexical-index.wbli")
    parser.add_argument(
        "--output",
        type=Path,
        help="write JSON to this path instead of standard output",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        output = export_inventory(args.source)
        if args.output is None:
            sys.stdout.buffer.write(output)
        else:
            args.output.write_bytes(output)
    except (InventoryError, OSError) as error:
        print(f"lexical inventory export failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
