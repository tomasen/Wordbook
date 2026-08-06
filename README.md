# Wordbook

https://wordbook.cool

Wordbook is a vocabulary builder that enables you to add new words by selecting and sharing text from any App via iOS system options.

## Review sharing word cloud

The daily review image uses deterministic, collision-free word packing. Eight stable placement variants are evaluated against the Word Cloud's actual container aspect ratio, then the layout with the best normalized fit is selected. The Cloud consumes the space left by the title, footer, and controls instead of deriving a square from `UIScreen.main`, so iPhone portrait, iPad and Mac 4:3 windows, 16:9 windows, and narrow split views each receive a layout shaped for their real available area. Equal review weights receive a medium size, while mixed weights use a square-root curve from 20 to 60 points so medium-priority words remain visible without obscuring the hardest words.

Labels are measured once at their reference font sizes. The chosen topology is then uniformly scaled as a whole, preserving the fonts and spacing without the former resize/re-measure loop that could oscillate and leave the Cloud blank. The topology cache is keyed by the words, measured label sizes, and current container aspect ratio, so rotation and window resizing cannot reuse an incompatible layout.

A review day runs from 4:00 AM local time through, but not including, 4:00 AM the next day. Day IDs and query bounds use local civil-calendar arithmetic, including 23- and 25-hour daylight-saving days. This avoids the former Unix-epoch offset that made morning and afternoon answers appear under different days in time zones such as Los Angeles; the Word Cloud and its footer rebuild today's cached totals from `AnswerHistory` when opened.

## Natural voice (iOS)

The main iOS app uses [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.5 and the English Kokoro-82M Core ML pipeline for on-device pronunciation. The deployment target is iOS 17 or later. Every card pronunciation uses the single bundled `af_heart` voice at speed `0.9`; there is no Apple system text-to-speech fallback and stored MP3 pronunciations are not played.

Kokoro is one voice model split into seven computational stages—not seven voices:

`Albert → PostAlbert → Alignment → Prosody → Noise → Vocoder → Tail`

Text is resolved through the bundled Misaki-derived English lexicon first, with the bundled Core ML grapheme-to-phoneme model handling words that are not in the lexicon. `SoundManager.playTTS(_:phonemes:)` also accepts an explicit Misaki-style IPA pronunciation when a curated override is needed.

### Startup and offline behavior

The normal interface is gated until the bundled models are initialized and both the local language model and natural voice have completed a discarded warm-up inference. The startup screen uses the user-facing title `Getting Wordbook ready` and reports short stages such as checking language resources, loading the local language model, getting explanations ready, and getting pronunciation ready. Its expectation-setting copy is the neutral `Initial setup can take a little longer.`; a small clock and live timer sit at the bottom instead of competing with the current stage. The layout is intentionally restrained: a simple book icon, clear type hierarchy, and one bordered status panel on the existing dark theme, with no decorative animation or lighting effects. This moves deferred Metal/Core ML first-inference work ahead of the first card. After the gate disappears, individual pronunciations run without progress UI and only failures are shown. This is local initialization/device compilation, not a model download.

All required runtime assets ship in `NaturalVoiceModels/`:

- Six acoustic `.mlmodelc` stages, the Tail weight bundle, Kokoro vocabulary, and the `af_heart` voice pack remain in the signed app bundle. Wordbook loads the first six stages with Core ML and executes the final Tail/iSTFT stage with Accelerate.
- The English G2P encoder/decoder, G2P vocabulary, and lexicon are atomically copied to `Library/Application Support/fluidaudio/Models/kokoro` before FluidAudio initializes.
- The copy is necessary because FluidAudio 0.15.5 accepts a custom directory for the acoustic pipeline but its shared English G2P singleton uses the default FluidAudio cache path.
- `ModelHub.offlineMode` is enabled before initialization. With the shipped acoustic, voice, G2P, and lexicon assets present, FluidAudio takes no runtime download path.
- Upgrades remove the obsolete full acoustic-model cache created by older downloading builds. User vocabulary and study data are not touched.

FluidAudio is Apache-2.0 open source. Wordbook vendors the 0.15.5 library source under `Vendor/FluidAudio` so the Tail fix is reproducible and reviewable instead of being an edit to Xcode's disposable DerivedData checkout. `Vendor/FluidAudio/WORDBOOK_PATCH.md` records the upstream commit, patch rationale, validation, and retained licenses. Removing the G2P cache copy entirely would require an additional source change so FluidAudio's shared English G2P singleton accepts the caller's model directory.

### OS compatibility

The repeatable `silica` failure on an iPhone Air running iOS 26.6 was isolated to FluidAudio's final dynamic-shape `KokoroTail.mlmodelc` prediction. A shorter warm-up input succeeded, then a longer Tail input caused Apple's E5RT/BNNS implementation to reuse a scratch allocation sized for the previous shape and terminate in `BNNSGraphContextExecute_v2`. Serialization, compute-unit routing, fixed padding, and caller-provided output storage did not correct the native runtime fault. Wordbook therefore parses the Tail's four bundled Float32 weight tensors and performs its Conv1D, spectral reconstruction, transposed convolution, subtraction, and crop directly with Swift and Accelerate. The resulting samples were compared against Core ML at both relevant shapes with maximum absolute error below `5e-7`, and the unsafe seventh Core ML prediction is no longer called.

On the physical iPhone Air, the patched pipeline completed a warm-up followed by 60 varying-length pronunciations (ten cycles each of `silica`, `ready`, `caudate`, `fecund`, `covet`, and `lapidary`). Every synthesis returned a valid WAV payload and the process remained alive. This automated check verifies runtime stability only; pronunciation quality still requires human listening.

The source fix replaces the former OS-version kill switch: pronunciation is not silently disabled on iOS 26.4–26.6. Natural-voice initialization and warm-up must succeed before the main interface opens; a recoverable preparation error is shown with Retry. The [upstream controlled reproducer](https://github.com/FluidInference/FluidAudio/issues/817) and [earlier minimal reproducer](https://github.com/FluidInference/FluidAudio/issues/587) remain useful context for related Core ML failures.

Wordbook also permits only one large inference operation at a time across the local tutor and natural voice. It consumes each tutor decode while holding MLX Swift LM's serial model access, gives pronunciation priority at safe job boundaries, and never cancels an in-progress Core ML prediction. Pronunciation uses one worker with one replaceable pending request: a running synthesis finishes safely and is cached, repeated taps for the same word reuse that work, and only the newest different word remains pending. Audio-session activation and player startup failures are reported instead of being treated as successful silence. The playback category leaves Bluetooth A2DP routing implicit, as required for output-only sessions on current iOS, while `mixWithOthers` keeps pronunciation from unnecessarily stopping other audio. These safeguards prevent accelerator contention and keep interaction deterministic; the native Tail specifically removes the confirmed length-change crash. Wordbook does not fall back to system text-to-speech.

On a card, the whole-card reveal gesture belongs only to the visible front. The definition side gives its title button sole ownership of pronunciation taps, and the hidden card face does not participate in hit testing. This prevents the disabled flip gesture used by direct explanation links, including the review word cloud, from consuming a title tap without action.

The raw bundled natural-voice payload is 94,765,522 bytes (about 90.38 MiB): 78.91 MiB for the acoustic pipeline and 11.46 MiB for the frontend. The frontend is also copied into app data during the first-launch setup. These are raw payload sizes, not App Store download or installed-size estimates; signing, compression, and thinning affect those values.

### Source checkout and release verification

Natural-voice assets use Git LFS. A fresh development checkout still needs network access to retrieve Git LFS objects and Swift package dependencies:

```sh
git lfs install
git lfs pull
(cd NaturalVoiceModels && shasum -a 256 -c manifest.sha256)
```

`manifest.sha256` records the 49 source payload hashes for release/CI verification. Runtime code intentionally does not compare those hashes: the app signature protects bundled resources, Core ML validates models while loading, and iOS may transform compiled `.mlmodelc` contents during device installation. Runtime performs only the packaging checks needed to prevent a missing asset from falling through to a downloader.

When updating FluidAudio or the models, re-audit its G2P cache path and required filenames, regenerate `manifest.sha256`, and bump `BundledNaturalVoiceAssets.version` so an existing frontend cache is replaced.

Licenses and exact model provenance are included in the in-app About text at `Shared/about.txt`. Wordbook itself remains MIT licensed.

## Local vocabulary tutor (iOS)

Word explanations are generated completely on-device by a bundled, text-only 4-bit build of [Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B). The app uses the [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) runtime and its XGrammar-backed guided-generation library to constrain every generated token to a small JSON schema, instead of rejecting free-form output after generation. Both the full and minimal fallback schemas are compiled during the startup gate to validate them and warm the grammar bridge. The pinned xgrammar revision cannot fork matcher state, so each request follows MLX Swift LM's compatibility path and creates a fresh matcher from the already prepared tokenizer; this is a small fixed grammar cost, not another model load. A narrow prompt produces the target's most common established sense. Explanations begin directly with the meaning instead of a formula such as “the word means,” and include a part-of-speech label, one natural example sentence, up to three close synonyms when accurate ones exist, and an optional one- or two-sentence memory aid. Technical names normally omit synonyms rather than showing merely related terms. Generated content can still be imperfect. The result is cached in the existing Core Data store and may synchronize through Core Data/CloudKit; inference itself never uses a server.

The memory aid chooses a technique suited to the word: genuine visible present-day word parts, a useful spelling feature, vivid image, clear sound association, or useful contrast. Accuracy is more important than filling the section, so the model may omit the aid entirely. Validation rejects unfinished text and literal ellipses, repeated or redundant sentences, invented historical origins, and arbitrary single-letter, letter-shape, repeated-letter, or acronym tricks. The aid appears beneath the definition, synonyms, and example without a cryptic label; an invalid aid is omitted without hiding the valid definition. Cached explanations include a prompt version, so this stricter contract invalidates and replaces older memory aids when a word is next opened.

The card preserves Wordbook's compact definition presentation: the part of speech sits beside the meaning, synonyms appear as inline `Similar:` links, and the example is an italic bullet below it. Per-word generation is intentionally quiet—there is no spinner, progress message, or explanation playback button. A static version of Wordbook's original block-glyph placeholder holds the definition layout only while a missing explanation is being generated. If the complete result still fails semantic validation, Wordbook automatically runs one bounded second pass with a smaller schema containing only part of speech, meaning, and example; the old deterministic manual retry is no longer the first response to a harmless formatting failure.

Before the user starts or continues a study session, Wordbook reserves the exact upcoming word and begins its explanation in the background. It does the same for the next word after an answer. The card checks the versioned persistent cache synchronously and joins any matching in-flight request, so a completed prefetch appears immediately and the same word is never generated twice concurrently. Different-word requests may be queued together, but their full decode streams execute one at a time. Tutor and pronunciation inference also share an application-wide gate; pronunciation gets the next safe slot instead of overlapping a tutor decode. Model loading and a complete warm-up inference remain part of the startup preparation gate.

The Wikipedia summary card and the `news`, `images`, `web`, and `translate` discovery buttons remain available beneath the local explanation. They are optional network features and never supply or replace the main definition. Vocabulary.com remains removed.

There is no runtime model download, remote explanation fallback, or call to `api.wordbook.cool`. The former WordNet SQLite files and Vocabulary.com explanation path have been removed. Autocomplete, spelling aliases, random words, and COCA/BASIC/TOEFL/SAT/GRE selection now use the 4.82 MiB memory-mapped `Shared/lexical-index.wbli`, which contains spellings and book membership but no definitions.

The model payload in `LocalModels/Qwen3.5-2B-4bit-text/` is 1,059,405,152 bytes. It is derived from `mlx-community/Qwen3.5-2B-4bit` revision `674aaa7240b91e8012fcad5d791b7dfe5ba90207`; 297 unused `vision_tower.*` tensors were removed and all 694 `language_model.*` tensors were retained. `manifest.json` records provenance, byte sizes, and SHA-256 hashes. The model is Apache-2.0 licensed and its license ships beside it.

The 1 GiB `model.safetensors` payload is deliberately not stored in Git. After cloning the repository, prepare it before opening or building the Xcode project:

```sh
python3 scripts/setup_local_model.py
```

The setup script uses only the Python standard library, downloads from the pinned Hugging Face revision above, and uses HTTP Range requests to fetch only the safetensors header and the 694 text-model tensors when the server supports ranges. It reconstructs the text-only file beside the tracked model metadata, then checks its exact 1,059,405,152-byte size and SHA-256 `b93b36a825ff36ef68eb4249295ac24942e15d67794e9747961e1640fe8a9b39` before atomically installing it. A valid existing model is left untouched. This download is a developer setup step only; the built app still bundles the verified model and runs tutor inference completely offline.

The iOS target pins `mlx-swift-lm` revision `38927f5f3da6d4720ac952f4d97f88d4424f11aa`, MLX Swift 0.31.6, and Swift Transformers 1.3.0. Building MLX for a physical device requires Xcode's optional Metal Toolchain.

Watch and Share extensions do not load the language model. The Share extension queues words for the phone, and Watch displays explanations that have already been generated and synchronized through Core Data/CloudKit.

### Future comprehension checks

The tutor boundary is intentionally separate from review scheduling. A future quiz can ask the learner for a typed explanation—or text transcribed by a separate speech-recognition component—and request a structured semantic assessment from the same local model. The deterministic study engine remains responsible for grades, intervals, and due dates; model output must never directly mutate scheduling data.
