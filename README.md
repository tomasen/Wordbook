# Wordbook

https://wordbook.cool

Wordbook is a vocabulary builder that enables you to add new words by selecting and sharing text from any App via iOS system options.

## Natural voice (iOS)

The main iOS app uses [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.5 and the English Kokoro-82M Core ML pipeline for on-device pronunciation. The deployment target is iOS 17 or later. Every card pronunciation uses the single bundled `af_heart` voice at speed `0.9`; there is no Apple system text-to-speech fallback and stored MP3 pronunciations are not played.

Kokoro is one model split into seven required Apple Neural Engine stages—not seven voices:

`Albert → PostAlbert → Alignment → Prosody → Noise → Vocoder → Tail`

Text is resolved through the bundled Misaki-derived English lexicon first, with the bundled Core ML grapheme-to-phoneme model handling words that are not in the lexicon. `SoundManager.playTTS(_:phonemes:)` also accepts an explicit Misaki-style IPA pronunciation when a curated override is needed.

### Startup and offline behavior

The normal interface is gated until the bundled model is initialized. During startup, the app shows only `Preparing…`; after that gate disappears, individual pronunciations run without progress UI and only failures are shown. In physical-device debug measurements on an iPhone Air, the first launch after installation took 8.36 seconds while Core ML prepared the models, and an immediate warm relaunch took 0.16 seconds. This is local initialization/device compilation, not a model download.

All required runtime assets ship in `NaturalVoiceModels/`:

- The seven acoustic `.mlmodelc` stages, Kokoro vocabulary, and `af_heart` voice pack remain in the signed app bundle.
- The English G2P encoder/decoder, G2P vocabulary, and lexicon are atomically copied to `Library/Application Support/fluidaudio/Models/kokoro` before FluidAudio initializes.
- The copy is necessary because FluidAudio 0.15.5 accepts a custom directory for the acoustic pipeline but its shared English G2P singleton uses the default FluidAudio cache path.
- `ModelHub.offlineMode` is enabled before initialization. With the shipped acoustic, voice, G2P, and lexicon assets present, FluidAudio takes no runtime download path.
- Upgrades remove the obsolete full acoustic-model cache created by older downloading builds. User vocabulary and study data are not touched.

FluidAudio is Apache-2.0 open source. Removing the G2P cache copy entirely would require changing that singleton to accept the caller's model directory, then contributing the change upstream or pinning Wordbook to a maintained fork. Do not edit Xcode's DerivedData package checkout because package resolution will discard that change.

The raw bundled natural-voice payload is 94,765,522 bytes (about 90.38 MiB): 78.91 MiB for the acoustic pipeline and 11.46 MiB for the frontend. The frontend is also copied into app data on first preparation. These are raw payload sizes, not App Store download or installed-size estimates; signing, compression, and thinning affect those values.

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
