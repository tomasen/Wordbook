from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT_FILE = ROOT / "Wordbook.xcodeproj" / "project.pbxproj"

IOS_TARGET_ID = "88E02DFA27061D270015ECEA"
IOS_RESOURCE_PHASE_ID = "88E02DF927061D270015ECEA"
RELEASE_GATE_PHASE_ID = "C20000012FA0000100000001"
IOS_DEBUG_CONFIGURATION_ID = "88E02E2927061D280015ECEA"
IOS_RELEASE_CONFIGURATION_ID = "88E02E2A27061D280015ECEA"
OTHER_TARGET_IDS = (
    "88129511277F1EEA008F1B1B",
    "88129519277F1EEC008F1B1B",
    "8833AC1E274FE90400637B61",
    "883B9ACE2785DA6300287A37",
    "88E02E0727061D280015ECEA",
)


def object_block(project: str, object_id: str) -> str:
    match = re.search(
        rf"^[ \t]*{re.escape(object_id)}\s+/\*[^\n]*\*/\s*=\s*\{{",
        project,
        re.MULTILINE,
    )
    if match is None:
        raise AssertionError(f"missing PBX object {object_id}")
    opening = project.find("{", match.start())
    depth = 0
    for index in range(opening, len(project)):
        if project[index] == "{":
            depth += 1
        elif project[index] == "}":
            depth -= 1
            if depth == 0:
                return project[match.start() : index + 2]
    raise AssertionError(f"unterminated PBX object {object_id}")


class ReleaseContentBuildGateProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project = PROJECT_FILE.read_text(encoding="utf-8")

    def test_gate_is_only_on_shipping_target_and_precedes_resource_copy(self) -> None:
        ios_target = object_block(self.project, IOS_TARGET_ID)
        self.assertIn(RELEASE_GATE_PHASE_ID, ios_target)
        self.assertLess(
            ios_target.index(RELEASE_GATE_PHASE_ID),
            ios_target.index(IOS_RESOURCE_PHASE_ID),
        )
        for target_id in OTHER_TARGET_IDS:
            self.assertNotIn(RELEASE_GATE_PHASE_ID, object_block(self.project, target_id))

    def test_gate_is_read_only_repeatable_and_declares_its_inputs(self) -> None:
        phase = object_block(self.project, RELEASE_GATE_PHASE_ID)
        self.assertIn("isa = PBXShellScriptBuildPhase;", phase)
        self.assertIn("alwaysOutOfDate = 1;", phase)
        self.assertIn("$(SRCROOT)/Shared/wordbook-content.sqlite", phase)
        self.assertIn("$(SRCROOT)/scripts/validate_release_content_pack.py", phase)
        self.assertIn("$(WORDBOOK_CONTENT_BUILD_RECEIPT_PATH)", phase)
        self.assertIn("--app-build", phase)
        self.assertNotIn("sqlite3 ", phase)
        self.assertNotIn("install_signed_content_release", phase)

    def test_shell_exits_before_validation_outside_release(self) -> None:
        phase = object_block(self.project, RELEASE_GATE_PHASE_ID)
        shell = phase[phase.index("shellScript =") :]
        configuration_check = shell.index("${CONFIGURATION}")
        validation = shell.index("validate_release_content_pack.py")
        self.assertLess(configuration_check, validation)
        self.assertIn("!= \\\"Release\\\"", shell)
        self.assertIn("exit 0", shell)

    def test_debug_uses_existing_placeholder_and_release_requires_real_receipt(self) -> None:
        debug = object_block(self.project, IOS_DEBUG_CONFIGURATION_ID)
        release = object_block(self.project, IOS_RELEASE_CONFIGURATION_ID)
        self.assertIn(
            "scripts/Fixtures/debug-content-build-receipt-placeholder.json",
            debug,
        )
        self.assertIn("Shared/.wordbook-content-build-receipt.json", release)
        self.assertTrue(
            (ROOT / "scripts/Fixtures/debug-content-build-receipt-placeholder.json")
            .is_file()
        )


if __name__ == "__main__":
    unittest.main()
