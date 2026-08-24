from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT_FILE = ROOT / "Wordbook.xcodeproj" / "project.pbxproj"
SHARED_SCHEMES = ROOT / "Wordbook.xcodeproj" / "xcshareddata" / "xcschemes"

PROJECT_ID = "88E02DEC27061D260015ECEA"
IOS_TARGET_ID = "88E02DFA27061D270015ECEA"
NATIVE_MAC_TARGET_ID = "88E02E0027061D270015ECEA"
NATIVE_MAC_TEST_TARGET_ID = "88E02E1327061D280015ECEA"
NATIVE_MAC_RESOURCE_PHASE_ID = "88E02DFF27061D270015ECEA"


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
        character = project[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return project[match.start() : index + 2]
    raise AssertionError(f"unterminated PBX object {object_id}")


def list_value(block: str, key: str) -> str:
    match = re.search(rf"\b{re.escape(key)}\s*=\s*\(", block)
    if match is None:
        raise AssertionError(f"missing list {key}")
    opening = block.find("(", match.start())
    depth = 0
    for index in range(opening, len(block)):
        character = block[index]
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return block[opening + 1 : index]
    raise AssertionError(f"unterminated list {key}")


def referenced_ids(value: str) -> list[str]:
    return re.findall(r"\b[A-F0-9]{24}\b", value)


class MacCatalystProjectContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project = PROJECT_FILE.read_text(encoding="utf-8")
        cls.project_object = object_block(cls.project, PROJECT_ID)
        cls.ios_target = object_block(cls.project, IOS_TARGET_ID)

    def test_catalyst_app_is_the_only_active_mac_application_path(self) -> None:
        active_targets = referenced_ids(list_value(self.project_object, "targets"))

        self.assertIn(IOS_TARGET_ID, active_targets)
        self.assertNotIn(NATIVE_MAC_TARGET_ID, active_targets)
        self.assertNotIn(NATIVE_MAC_TEST_TARGET_ID, active_targets)

        for target_id in active_targets:
            target = object_block(self.project, target_id)
            configuration_list_match = re.search(
                r"buildConfigurationList\s*=\s*([A-F0-9]{24})",
                target,
            )
            self.assertIsNotNone(configuration_list_match)
            configuration_list = object_block(
                self.project,
                configuration_list_match.group(1),
            )
            for configuration_id in referenced_ids(
                list_value(configuration_list, "buildConfigurations")
            ):
                configuration = object_block(self.project, configuration_id)
                self.assertNotIn("SDKROOT = macosx;", configuration)

    def test_ios_target_keeps_complete_catalyst_dependencies(self) -> None:
        dependencies = list_value(self.ios_target, "packageProductDependencies")
        for product in (
            "FluidAudio",
            "MLXLLM",
            "MLXLMCommon",
            "MLXGuidedGeneration",
            "Tokenizers",
            "Introspect",
            "SwiftyStoreKit",
            "WebView",
        ):
            self.assertIn(f"/* {product} */", dependencies)

        framework_phase = object_block(self.project, "88E02DF827061D270015ECEA")
        for product in (
            "FluidAudio",
            "MLXLLM",
            "MLXLMCommon",
            "MLXGuidedGeneration",
            "Tokenizers",
            "Introspect",
            "SwiftyStoreKit",
            "WebView",
        ):
            self.assertIn(f"/* {product} in Frameworks */", framework_phase)

    def test_catalyst_uses_the_full_application_resource_set(self) -> None:
        resource_phase = object_block(self.project, "88E02DF927061D270015ECEA")
        for resource in (
            "PrivacyInfo.xcprivacy",
            "wordbook-content.sqlite",
            "NaturalVoiceModels",
            "lexical-index.wbli",
            "LocalModels",
            "LaunchScreen.storyboard",
        ):
            self.assertIn(resource, resource_phase)

    def test_debug_and_release_select_catalyst_not_designed_for_ipad(self) -> None:
        configuration_list_match = re.search(
            r"buildConfigurationList\s*=\s*([A-F0-9]{24})",
            self.ios_target,
        )
        self.assertIsNotNone(configuration_list_match)
        configuration_list = object_block(
            self.project,
            configuration_list_match.group(1),
        )
        configuration_ids = referenced_ids(
            list_value(configuration_list, "buildConfigurations")
        )
        self.assertEqual(len(configuration_ids), 2)

        for configuration_id in configuration_ids:
            configuration = object_block(self.project, configuration_id)
            self.assertIn(
                'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";',
                configuration,
            )
            self.assertIn("SUPPORTS_MACCATALYST = YES;", configuration)
            self.assertIn(
                "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;",
                configuration,
            )
            self.assertIn('TARGETED_DEVICE_FAMILY = "1,2";', configuration)
            self.assertIn("WORDBOOK_NATURAL_VOICE", configuration)
            self.assertIn("WORDBOOK_LOCAL_LLM", configuration)
            self.assertIn("WORDBOOK_EXPLANATION_REPOSITORY", configuration)

    def test_no_native_mac_scheme_or_ios_launch_screen_build_path(self) -> None:
        shared_scheme_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(SHARED_SCHEMES.glob("*.xcscheme"))
        )
        self.assertNotIn(NATIVE_MAC_TARGET_ID, shared_scheme_text)
        self.assertNotIn('BlueprintName = "Wordbook (macOS)"', shared_scheme_text)

        orphaned_native_resources = object_block(
            self.project,
            NATIVE_MAC_RESOURCE_PHASE_ID,
        )
        self.assertNotIn("LaunchScreen.storyboard", orphaned_native_resources)

    def test_documentation_advertises_only_catalyst_for_mac(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn(
            "single shipping application target for iPhone, iPad, and Mac Catalyst",
            readme,
        )
        self.assertIn("Catalyst is the only supported Mac runtime", readme)
        self.assertNotIn("iOS and native macOS app targets", readme)


if __name__ == "__main__":
    unittest.main()
