import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


SCRIPT = Path(__file__).resolve().parents[1] / "export_lexical_inventory.py"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("export_lexical_inventory", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
EXPORTER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EXPORTER
SPEC.loader.exec_module(EXPORTER)


DEFAULT_SPELLINGS = ("A", "child", "go", "go to bed", "read", "saw", "two words")
DEFAULT_ALIASES = (
    ("", ()),
    ("children", (1,)),
    ("GO", (2,)),
    ("reads", (4,)),
    ("went", (3, 2)),
)
DEFAULT_BOOKS = (("BASIC", (1, 4)), ("GRE", (2, 4)))


def synthetic_index(
    spellings=DEFAULT_SPELLINGS,
    aliases=DEFAULT_ALIASES,
    books=DEFAULT_BOOKS,
):
    word_bytes = b"".join(spelling.encode("utf-8") for spelling in spellings)
    word_offsets = [0]
    for spelling in spellings:
        word_offsets.append(word_offsets[-1] + len(spelling.encode("utf-8")))

    header_size = 88
    word_offsets_offset = header_size
    packed_word_offsets = struct.pack(f"<{len(word_offsets)}I", *word_offsets)
    word_bytes_offset = word_offsets_offset + len(packed_word_offsets)
    phrase_bits_offset = word_bytes_offset + len(word_bytes)
    phrase_bits = bytearray((len(spellings) + 7) // 8)
    for index, spelling in enumerate(spellings):
        if " " in spelling:
            phrase_bits[index >> 3] |= 1 << (index & 7)
    alias_string_offsets_offset = phrase_bits_offset + len(phrase_bits)
    alias_bytes = b"".join(surface.encode("utf-8") for surface, _ in aliases)
    alias_string_offset_values = [0]
    for surface, _ in aliases:
        alias_string_offset_values.append(
            alias_string_offset_values[-1] + len(surface.encode("utf-8"))
        )
    alias_string_offsets = struct.pack(
        f"<{len(alias_string_offset_values)}I", *alias_string_offset_values
    )
    alias_bytes_offset = alias_string_offsets_offset + len(alias_string_offsets)
    alias_target_offsets_offset = alias_bytes_offset + len(alias_bytes)
    alias_target_offset_values = [0]
    alias_target_values = []
    for _, targets in aliases:
        alias_target_values.extend(targets)
        alias_target_offset_values.append(len(alias_target_values))
    alias_target_offsets = struct.pack(
        f"<{len(alias_target_offset_values)}I", *alias_target_offset_values
    )
    alias_targets_offset = alias_target_offsets_offset + len(alias_target_offsets)
    alias_targets = (
        struct.pack(f"<{len(alias_target_values)}I", *alias_target_values)
        if alias_target_values
        else b""
    )
    book_records_offset = alias_targets_offset + len(alias_targets)
    book_index_values = []
    metadata_strings = b""
    book_records = bytearray()
    for tag, indices in books:
        encoded_tag = tag.encode("utf-8")
        tag_start = len(metadata_strings)
        metadata_strings += encoded_tag
        index_start = len(book_index_values)
        book_index_values.extend(indices)
        book_records.extend(
            struct.pack("<4I", tag_start, len(encoded_tag), index_start, len(indices))
        )
    book_indices_offset = book_records_offset + len(book_records)
    book_indices = (
        struct.pack(f"<{len(book_index_values)}I", *book_index_values)
        if book_index_values
        else b""
    )
    metadata_strings_offset = book_indices_offset + len(book_indices)

    payload = b"".join(
        (
            packed_word_offsets,
            word_bytes,
            bytes(phrase_bits),
            alias_string_offsets,
            alias_bytes,
            alias_target_offsets,
            alias_targets,
            bytes(book_records),
            book_indices,
            metadata_strings,
        )
    )
    file_size = header_size + len(payload)
    checksum = zlib.crc32(payload) & 0xFFFF_FFFF
    header = struct.pack(
        "<8s20I",
        b"WBLXIDX\0",
        1,
        header_size,
        file_size,
        len(spellings),
        len(aliases),
        len(alias_target_values),
        len(books),
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
        len(metadata_strings),
        checksum,
        1,
    )
    return header + payload


class LexicalInventoryExporterTests(unittest.TestCase):
    def test_exports_exact_spellings_and_source_identity(self):
        source = synthetic_index()
        inventory = EXPORTER.parse_lexical_index(source)

        self.assertEqual(inventory.canonical_spellings, DEFAULT_SPELLINGS)
        document = json.loads(EXPORTER.serialize_inventory(inventory))
        self.assertEqual(document["inventoryKind"], "bundledLexicalReleaseInventory")
        self.assertEqual(document["schemaVersion"], 2)
        self.assertEqual(document["canonicalEntries"]["spellings"], list(DEFAULT_SPELLINGS))
        self.assertEqual(document["source"]["wordCount"], len(DEFAULT_SPELLINGS))
        self.assertEqual(document["source"]["aliasCount"], len(DEFAULT_ALIASES))
        self.assertEqual(document["source"]["bookCount"], len(DEFAULT_BOOKS))
        self.assertEqual(document["source"]["sha256"], hashlib.sha256(source).hexdigest())
        self.assertEqual(
            document["source"]["payloadCRC32"],
            f"{zlib.crc32(source[88:]) & 0xFFFF_FFFF:08x}",
        )

    def test_exports_deduplicated_vocabulary_book_union_as_canonical_targets(self):
        document = json.loads(
            EXPORTER.serialize_inventory(EXPORTER.parse_lexical_index(synthetic_index()))
        )
        study = document["studyTargets"]
        self.assertEqual(study["kind"], "canonicalUnionOfBundledVocabularyBooks")
        self.assertEqual(study["bookTags"], ["BASIC", "GRE"])
        self.assertEqual(study["spellingCount"], 3)
        self.assertEqual(study["spellings"], ["child", "go", "read"])

    def test_reports_alias_only_surfaces_without_merging_identity(self):
        document = json.loads(
            EXPORTER.serialize_inventory(EXPORTER.parse_lexical_index(synthetic_index()))
        )
        alias_inventory = document["aliasOnlyStudySurfaces"]
        self.assertEqual(
            alias_inventory["kind"],
            "aliasOnlySurfacesWithStudyCanonicalMappings",
        )
        mappings = {mapping["surface"]: mapping for mapping in alias_inventory["mappings"]}
        self.assertEqual(set(mappings), {"children", "reads", "went"})
        self.assertNotIn("GO", mappings)  # Canonical lookup wins case-insensitively.
        self.assertEqual(mappings["children"]["studyCanonicalTargets"], ["child"])
        self.assertEqual(mappings["went"]["studyCanonicalTargets"], ["go"])
        self.assertEqual(mappings["went"]["runtimePrimaryCanonicalTarget"], "go to bed")
        self.assertEqual(mappings["went"]["canonicalTargetCount"], 2)
        self.assertEqual(alias_inventory["surfaceCount"], 3)

    def test_serialization_is_byte_deterministic(self):
        inventory = EXPORTER.parse_lexical_index(synthetic_index())
        self.assertEqual(
            EXPORTER.serialize_inventory(inventory),
            EXPORTER.serialize_inventory(inventory),
        )

    def test_rejects_payload_checksum_mismatch(self):
        source = bytearray(synthetic_index())
        source[-1] ^= 0x01
        with self.assertRaisesRegex(EXPORTER.InventoryError, "CRC-32 mismatch"):
            EXPORTER.parse_lexical_index(bytes(source))

    def test_rejects_unsorted_canonical_words(self):
        source = synthetic_index(("saw", "read"), aliases=(), books=())
        with self.assertRaisesRegex(EXPORTER.InventoryError, "not ASCII-case-folded sorted"):
            EXPORTER.parse_lexical_index(source)

    def test_cli_writes_same_document_as_library(self):
        source = synthetic_index()
        with tempfile.TemporaryDirectory() as directory:
            source_path = Path(directory) / "fixture.wbli"
            output_path = Path(directory) / "inventory.json"
            source_path.write_bytes(source)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), str(source_path), "--output", str(output_path)],
                check=False,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(
                output_path.read_bytes(),
                EXPORTER.serialize_inventory(EXPORTER.parse_lexical_index(source)),
            )

    def test_current_release_inventory_identity_and_counts(self):
        source = (REPOSITORY_ROOT / "Shared" / "lexical-index.wbli").read_bytes()
        document = EXPORTER.parse_lexical_index(source).document()

        self.assertEqual(
            document["source"]["sha256"],
            "57d38efd90b197f12c0242ca5ed672379f7081c4619920b96083ff0fd1f3845a",
        )
        self.assertEqual(document["source"]["wordCount"], 149_400)
        self.assertEqual(document["source"]["aliasCount"], 105_131)
        self.assertEqual(document["source"]["bookCount"], 6)
        self.assertEqual(document["studyTargets"]["spellingCount"], 16_577)
        self.assertEqual(document["aliasOnlyStudySurfaces"]["surfaceCount"], 22_115)


if __name__ == "__main__":
    unittest.main()
