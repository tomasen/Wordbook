import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class EntryClientP0ContractTests(unittest.TestCase):
    def source(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_preflight_starts_exact_runtime_outbox_pass(self) -> None:
        source = self.source("Shared/WordbookApp.swift")
        method = source[source.index("private func prepareExplanationLibrary()") :]
        repository_check = method.index("if runtime.repository != nil")
        delivery = method.index("runtime.deliverPendingFeedbackOnce()")
        ready = method.index("return ExplanationLibraryPreparationState.ready")
        self.assertLess(repository_check, delivery)
        self.assertLess(delivery, ready)

        runtime = self.source("Shared/ExplanationRuntime.swift")
        entry_runtime = runtime[runtime.index("final class EntryExplanationRuntime") :]
        self.assertIn("attemptedPendingDelivery = true", entry_runtime)
        self.assertIn("func deliverPendingFeedbackOnce() -> Task<Void, Never>?", entry_runtime)
        self.assertIn("return nil", entry_runtime)

    def test_foreground_entry_and_replacement_have_one_status_budget(self) -> None:
        repository = self.source("Shared/ExplanationRepository.swift")
        self.assertIn("private(set) var remainingChecks = 1", repository)
        self.assertIn("if !allowPendingStatusCheck || pending.nextCheckAt > now()", repository)

        view_model = self.source("Shared/CardViewModel.swift")
        self.assertNotIn("pendingPollLimit", view_model)
        self.assertGreaterEqual(
            view_model.count("var statusBudget = EntryForegroundStatusCheckBudget()"),
            2,
        )
        self.assertIn("var allowPendingStatusCheck = false", view_model)
        self.assertIn("allowPendingStatusCheck: allowPendingStatusCheck", view_model)
        self.assertGreaterEqual(view_model.count("statusBudget.claimStatusCheck()"), 2)

        runtime = self.source("Shared/ExplanationRuntime.swift")
        entry_runtime = runtime[runtime.index("final class EntryExplanationRuntime") :]
        prefetch = entry_runtime[
            entry_runtime.index("func prefetchEntry") :
            entry_runtime.index("func deliverPendingFeedbackOnce")
        ]
        self.assertIn("allowPendingStatusCheck: false", prefetch)

    def test_local_model_is_only_the_ephemeral_last_explanation_fallback(self) -> None:
        models = self.source("Shared/ExplanationModels.swift")
        self.assertIn("case localFallback(VocabularyExplanation)", models)

        view_model = self.source("Shared/CardViewModel.swift")
        foreground = view_model[
            view_model.index("func fetchExplain(") :
            view_model.index("func retryExplanation()")
        ]
        # A missing catalog runtime, a bounded server-unavailable outcome, or
        # a transport failure may use the device model.  Correction, a known
        # negative spelling, and a still-reviewed job must remain authoritative.
        self.assertEqual(foreground.count("loadLocalFallback("), 3)
        self.assertIn("case .correctionRequired(let correction):", foreground)
        self.assertIn("case .negative:", foreground)
        self.assertIn("case .pending(let pending):", foreground)
        self.assertIn("case .unavailable:", foreground)

        fallback = view_model[
            view_model.index("private func loadLocalFallback") :
            view_model.index("func likeExplanation()")
        ]
        self.assertIn("LocalTutorManager.shared.explanation", fallback)
        self.assertIn("wordEntryState = .localFallback(explanation)", fallback)
        self.assertNotIn("save", fallback.lower())
        self.assertNotIn("feedback", fallback.lower())

        view = self.source("Shared/CardView.swift")
        self.assertIn("case .localFallback(let explanation):", view)
        self.assertIn("localFallbackLesson(explanation)", view)

    def test_confirmed_spelling_action_is_one_shot_and_cache_scoped(self) -> None:
        view = self.source("Shared/CardView.swift")
        self.assertIn('Button("This spelling is correct")', view)
        self.assertIn("viewModel.confirmRareSpelling()", view)

        view_model = self.source("Shared/CardViewModel.swift")
        self.assertIn("guard case .correctionRequired = wordEntryState", view_model)
        self.assertIn("rareSpellingConfirmationAttempted = true", view_model)
        self.assertIn("fetchExplain(confirmedRareSpelling: true)", view_model)

        repository = self.source("Shared/ExplanationRepository.swift")
        cached_miss = repository[
            repository.index("if let cached = try? overlay.cachedMiss") :
            repository.index("if let pending = try? overlay.pending")
        ]
        self.assertIn("if !confirmedRareSpelling", cached_miss)
        self.assertIn("return .correctionRequired(correction)", cached_miss)
        self.assertIn("return .negative(negative)", cached_miss)

    def test_purchase_copy_does_not_claim_serverless_generation(self) -> None:
        purchase = self.source("Shared/PurchaseView.swift")
        self.assertIn("Reviewed Explanations", purchase)
        self.assertIn("Rare spellings and feedback may contact", purchase)
        self.assertNotIn("no explanation server", purchase)
        self.assertNotIn("Private Local Tutor", purchase)

    def test_pronunciation_prefetch_waits_for_local_entry_once(self) -> None:
        runtime = self.source("Shared/ExplanationRuntime.swift")
        method_start = runtime.index("func preferredLocalPronunciationPhonemes")
        method = runtime[
            method_start : runtime.index("@discardableResult", method_start)
        ]
        self.assertIn("Task.detached", method)
        self.assertIn("resolveLocally(form: surfaceForm)", method)
        self.assertIn("entry.preferredPronunciationPhonemes", method)

        models = self.source("Shared/ExplanationModels.swift")
        selection = models[
            models.index("var preferredPronunciationPhonemes") :
            models.index("enum WordEntryLoadState")
        ]
        self.assertIn("preferredEntryUsageID", selection)
        self.assertIn("trimmingCharacters", selection)

        for relative_path in ("Shared/CardView.swift", "Shared/SimpleWordView.swift"):
            view = self.source(relative_path)
            self.assertIn(".task(id:", view)
            self.assertIn("preferredLocalPronunciationPhonemes", view)
            self.assertEqual(view.count(".preparePronunciation("), 1)
            self.assertNotIn(
                ".onChange(of: viewModel.preferredPronunciationPhonemes)",
                view,
            )
            self.assertNotIn(
                ".onChange(of: explanationViewModel.preferredPronunciationPhonemes)",
                view,
            )

    def test_watch_snapshot_uses_pinned_normalization_contract(self) -> None:
        models = self.source("Shared/ExplanationModels.swift")
        normalizer = models[
            models.index("static func normalizeLookupForm") :
            models.index("static func entryKey")
        ]
        self.assertIn("WordbookNormalizationV1.normalize(form)", normalizer)
        self.assertNotIn("lowercased(with:", normalizer)

        project = self.source("Wordbook.xcodeproj/project.pbxproj")
        watch_sources = project[
            project.index("88129516277F1EEC008F1B1B /* Sources */ =") :
            project.index("8833AC1B274FE90400637B61 /* Sources */ =")
        ]
        share_sources = project[
            project.index("8833AC1B274FE90400637B61 /* Sources */ =") :
            project.index("883B9ACB2785DA6300287A37 /* Sources */ =")
        ]
        self.assertEqual(project.count("A80000122F80000100000001"), 2)
        self.assertEqual(project.count("A80000132F80000100000001"), 2)
        self.assertIn("NormalizationV1.generated.swift in Sources", watch_sources)
        self.assertIn("NormalizationV1.generated.swift in Sources", share_sources)

    def test_privacy_manifests_are_target_specific_and_wired_once(self) -> None:
        with (ROOT / "Shared/PrivacyInfo.xcprivacy").open("rb") as handle:
            app_manifest = plistlib.load(handle)
        with (ROOT / "ShareExtension/PrivacyInfo.xcprivacy").open("rb") as handle:
            share_manifest = plistlib.load(handle)
        with (ROOT / "WatchKit Extension/PrivacyInfo.xcprivacy").open("rb") as handle:
            watch_manifest = plistlib.load(handle)

        expected_api = [{
            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
            "NSPrivacyAccessedAPITypeReasons": ["1C8F.1"],
        }]
        self.assertEqual(app_manifest["NSPrivacyAccessedAPITypes"], expected_api)
        self.assertEqual(share_manifest["NSPrivacyAccessedAPITypes"], expected_api)
        self.assertEqual(watch_manifest["NSPrivacyAccessedAPITypes"], expected_api)
        self.assertNotIn("NSPrivacyCollectedDataTypes", share_manifest)
        self.assertNotIn("NSPrivacyCollectedDataTypes", watch_manifest)
        collected = {
            item["NSPrivacyCollectedDataType"]: item
            for item in app_manifest["NSPrivacyCollectedDataTypes"]
        }
        self.assertEqual(
            set(collected),
            {
                "NSPrivacyCollectedDataTypeSearchHistory",
                "NSPrivacyCollectedDataTypeProductInteraction",
            },
        )
        self.assertTrue(all(not item["NSPrivacyCollectedDataTypeLinked"] for item in collected.values()))
        self.assertTrue(all(not item["NSPrivacyCollectedDataTypeTracking"] for item in collected.values()))

        project = self.source("Wordbook.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("B10000102F90000100000001"), 2)
        self.assertEqual(project.count("B10000112F90000100000001"), 2)
        self.assertEqual(project.count("B10000122F90000100000001"), 2)
        ios_resources = project[
            project.index("88E02DF927061D270015ECEA /* Resources */ =") :
            project.index("88E02DFF27061D270015ECEA /* Resources */ =")
        ]
        share_resources = project[
            project.index("8833AC1D274FE90400637B61 /* Resources */ =") :
            project.index("883B9ACD2785DA6300287A37 /* Resources */ =")
        ]
        watch_resources = project[
            project.index("88129518277F1EEC008F1B1B /* Resources */ =") :
            project.index("8833AC1D274FE90400637B61 /* Resources */ =")
        ]
        self.assertIn("B10000102F90000100000001", ios_resources)
        self.assertNotIn("B10000112F90000100000001", ios_resources)
        self.assertNotIn("B10000122F90000100000001", ios_resources)
        self.assertIn("B10000112F90000100000001", share_resources)
        self.assertNotIn("B10000102F90000100000001", share_resources)
        self.assertNotIn("B10000122F90000100000001", share_resources)
        self.assertIn("B10000122F90000100000001", watch_resources)
        self.assertNotIn("B10000102F90000100000001", watch_resources)
        self.assertNotIn("B10000112F90000100000001", watch_resources)


if __name__ == "__main__":
    unittest.main()
