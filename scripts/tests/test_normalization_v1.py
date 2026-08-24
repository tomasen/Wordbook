from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import normalization_v1  # noqa: E402


class NormalizationV1Tests(unittest.TestCase):
    def test_client_data_and_conformance_are_digest_bound(self):
        data = (SCRIPTS / "Fixtures/normalization-v1-data.json").read_bytes()
        fixture = json.loads(
            (SCRIPTS / "Fixtures/normalization-v1-conformance.json").read_text(
                encoding="utf-8"
            )
        )
        manifest = json.loads(
            (SCRIPTS / "Fixtures/normalization-v1-generated-manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(normalization_v1.CONTRACT_SHA256, hashlib.sha256(data).hexdigest())
        self.assertEqual(normalization_v1.CONTRACT_SHA256, fixture["contractSHA256"])
        self.assertEqual(
            manifest["artifacts"]["clientSwiftRuntime"],
            hashlib.sha256(
                (ROOT / "Shared/NormalizationV1.generated.swift").read_bytes()
            ).hexdigest(),
        )
        self.assertEqual(
            manifest["artifacts"]["clientPythonRuntime"],
            hashlib.sha256((SCRIPTS / "normalization_v1.py").read_bytes()).hexdigest(),
        )
        for case in fixture["normalizationCases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(case["normalized"], normalization_v1.normalize_form(case["input"]))
        for case in fixture["unsupportedNormalizationCases"]:
            with self.subTest(case=case["id"]):
                self.assertIsNone(normalization_v1.try_normalize_form(case["input"]))
        for case in fixture["resolverCases"]:
            with self.subTest(resolver=case["id"]):
                self.assertEqual(
                    case["normalized"],
                    normalization_v1.normalize_lookup_key(case["input"]),
                )
        for case in fixture["invalidResolverCases"]:
            with self.subTest(invalid_resolver=case["id"]):
                self.assertIsNone(
                    normalization_v1.try_normalize_lookup_key(case["input"])
                )
        self.assertIsNone(normalization_v1.try_normalize_form("\ud800"))

    def test_swift_uses_the_same_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "normalization-v1-harness"
            compile_result = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    str(ROOT / "Shared/NormalizationV1.generated.swift"),
                    str(SCRIPTS / "NormalizationV1Harness.swift"),
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertEqual(0, compile_result.returncode, compile_result.stderr)
            run_result = subprocess.run(
                [str(executable), str(SCRIPTS / "Fixtures/normalization-v1-conformance.json")],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertEqual(0, run_result.returncode, run_result.stderr)
            self.assertIn("Normalization-v1 harness passed", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
