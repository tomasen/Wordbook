# Wordbook

https://wordbook.cool

Wordbook is a vocabulary builder that enables you to add new words by selecting and sharing text from any App via iOS system options.

## Supported Apple platforms

The `Wordbook (iOS)` target is the single shipping application target for iPhone, iPad, and Mac Catalyst. Mac Catalyst uses the same UIKit interface, explanation repository, bundled SQLite content, local language model, and natural-voice resources as iPhone and iPad. The separate native AppKit target is no longer an advertised build target: it had diverged into a partial product without those local features and still compiled iOS-only interface code. Keeping one adaptive application path avoids two Mac products with different behavior.

For Mac development, select the shared `Wordbook (iOS)` scheme and a Mac Catalyst destination. “Designed for iPhone/iPad on Mac” is disabled, so Catalyst is the only supported Mac runtime. The review Word Cloud remains a centered square and adapts to the available Mac window without changing its confidence-driven topology.

## Review sharing word cloud

The daily review image uses deterministic, collision-free word packing inside a centered 1:1 canvas. The Cloud takes the largest square that fits between the title and footer, whether the surrounding interface is an iPhone portrait screen, an iPad or Mac window, landscape, or a narrow split view. Screen proportions can change the space around the Cloud but never stretch its topology into a tall or wide layout. Font size preserves the learner's answer confidence on a linear 22-to-50-point scale: a word answered `GOOD` is small, `VAGUE` is medium, and `NOIDEA` is large. Repeated difficulty remains ordered within the same bounded scale, and an equal-score cloud retains the rating's absolute size instead of forcing every word to medium.

Labels are measured once at their reference font sizes. The chosen topology is then uniformly scaled as a whole to fit the square, preserving the fonts and spacing without the former resize/re-measure loop that could oscillate and leave the Cloud blank. The topology cache is keyed by the words, measured label sizes, priorities, and the fixed square aspect; rotation and window resizing only rescale and recenter the same authored Cloud.

A review day runs from 4:00 AM local time through, but not including, 4:00 AM the next day. The Today card explains this in learner-facing language—`A new day begins at 4:00 AM.`—with the time formatted according to the device's 12- or 24-hour clock preference. Day IDs and query bounds use local civil-calendar arithmetic, including 23- and 25-hour daylight-saving days. This avoids the former Unix-epoch offset that made morning and afternoon answers appear under different days in time zones such as Los Angeles; the Word Cloud and its footer rebuild today's cached totals from `AnswerHistory` when opened.

Correct answers advance the spaced-repetition step only through the terminal tier. Further correct answers remain at that tier and keep the existing long review interval; legacy out-of-range step values are normalized instead of reaching a fatal scheduler path.

## Natural voice (iOS and Mac Catalyst)

The main iOS app uses [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.5 and the English Kokoro-82M Core ML pipeline for on-device pronunciation. The deployment target is iOS 17 or later. Every card pronunciation uses the single bundled `af_heart` voice at speed `0.9`; there is no Apple system text-to-speech fallback and stored MP3 pronunciations are not played.

Kokoro is one voice model split into seven computational stages—not seven voices:

`Albert → PostAlbert → Alignment → Prosody → Noise → Vocoder → Tail`

Text is resolved through the bundled Misaki-derived English lexicon first, with the bundled Core ML grapheme-to-phoneme model handling words that are not in the lexicon. `SoundManager.playTTS(_:phonemes:)` also accepts an explicit Misaki-style IPA pronunciation when a curated override is needed.

Pronunciation prefetch performs the fast overlay/catalog-only Entry lookup
before synthesis starts. A local reviewed Entry therefore uses its selected
Usage's IPA on the first request. Only a true local miss (or an older Entry
without pronunciation) enters Kokoro's bundled lexicon/G2P path, once; a later
Entry-state callback does not enqueue a second synthesis behind it.

### Startup and offline behavior

The normal interface is gated until both local foundations are ready: the signed Entry explanation library has passed its SQLite/runtime preflight, and the bundled natural-voice assets have been initialized with one discarded pronunciation to warm the Core ML pipeline. Entry explanations remain SQLite-first and never wait for the local language model, so that model is not loaded or warmed during ordinary startup. The startup screen uses the user-facing title `Getting Wordbook ready`, the explanation `Setting up pronunciation on this device.`, and a short status for the explanation-library check or natural-voice loader's current stage. Its expectation-setting copy is the neutral `Initial setup can take a little longer.`; that copy, a small clock, and the live timer are grouped at the bottom instead of competing with the current stage. The layout is intentionally restrained: a simple book icon, clear type hierarchy, and a compact inline spinner with secondary status text on the existing dark theme. The current stage has no card-like background or border, so it does not compete with the title; decorative animation and lighting effects are also omitted. After the gate disappears, individual pronunciations run without progress UI and only failures are shown. This is local initialization/device compilation, not a model download.

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

Wordbook permits only one accelerator-heavy operation at a time across the future local comprehension evaluator and natural voice. Ordinary Entry lookup and explanation prefetch use SQLite or the server and never wait for the local language model. Entry prefetch starts as soon as the upcoming spelling is known; pronunciation preparation proceeds independently, and the exact upcoming word is silently synthesized into the in-memory audio cache. Opening a word gives its foreground pronunciation priority over background reservations. A tap joins matching work already in flight instead of starting duplicate synthesis. Leaving or answering a card immediately removes its playback intent, so completed work cannot speak on a later screen, while an already executing Core ML prediction may still finish safely into cache. Preparation waiters are scoped to a specific cache generation and cancelled views relinquish queued work without cancelling Core ML mid-prediction. Audio-session activation and player startup failures are reported instead of being treated as successful silence. The playback category leaves Bluetooth A2DP routing implicit, as required for output-only sessions on current iOS, while `mixWithOthers` keeps pronunciation from unnecessarily stopping other audio. These safeguards prevent accelerator contention and keep interaction deterministic; the native Tail specifically removes the confirmed length-change crash. Wordbook does not fall back to system text-to-speech.

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

## Curated explanations and Entry-first content (iOS and Mac Catalyst)

### Current implementation and release status

The Entry-first client, schema-2 reader, writable cache, strict `/v3` wire
contract, content-pack installer, deterministic signed-release packager, and
signature-verifying release installer are implemented and tested in this
working tree. The currently installed ignored pack is a conformance artifact
containing 7 Entries and 13 Usages; it proves the contract and lookup path but
is not a production vocabulary release. Inventory, disposition, and trusted-
evidence preparation tooling also exists, but a complete release still
requires approved teaching briefs and lessons for the full target inventory,
a provisioned production signing key, a signed published artifact, a populated
PostgreSQL catalog, and a deployed `/v3` service. Unicode normalization is now
frozen to generated Unicode 15.1 data and conformance-tested across Swift,
Python, and Go. The production pipeline fails closed rather than exporting a
partially covered pack.

Release lessons have two truthful provenance arms. Ordinary content keeps its
generator plus independent model-review chain; the registered `saw` product
golden skips those calls only after its complete source template and human
sign-off match a repository-pinned trust root outside the manifest. It is
recorded as `humanProductGolden`, never as a model-reviewed candidate.

The deterministic inventory exporter measures the current bundled lexical
index as 149,400 canonical spellings. Of those, 16,577 are canonical targets in
the app's COCA/BASIC/TOEFL/SAT/GRE study lists, and another 22,115 are distinct
encountered forms used by those targets. Those 38,692 source surfaces normalize
to 38,683 exact-spelling Entries because nine capitalization pairs share one
case-folded lookup key; each Entry must retain the distinct common usages of
all source surfaces in that group. The pinned evidence audit admits 33,195 of
those surfaces as 33,186 evidence-backed teaching Entries. The remaining 5,497
alias-only Entries have no trusted definition evidence and are explicitly
recorded as unsupported/correction dispositions rather than receiving invented
lessons. The intended production split is therefore 33,186 bundled offline
teaching Entries, a deterministic disposition for every other source surface,
and the full 149,400-spelling candidate inventory on the server for verified
cold misses. A reviewed cold result becomes a local overlay hit immediately
and a candidate for the next bundled release.

### Pinned normalization and resolver shape

Catalog identity uses generated Unicode 15.1 tables, not Foundation's
OS-version-dependent normalization or character categories. The generated
contract digest is
`5899eac0b1207a3ecf10cedfff5c984d8e0c188267073f125347b307e95f4f52`.
Its phrase-capable primitive preserves historical local keys such as
`A.M.` -> `a.m.`; a separate bounded resolver validator is applied only to
actual server lookup surfaces. That validator accepts ordinary compounds,
possessives, elisions, dotted abbreviations, and slash forms such as
`jack-o'-lantern`, `Achilles' heel`, `etc.`, `U.S.`, `read/write`, and `24/7`,
while rejecting controls, unlisted punctuation, leading decimals, more than
four tokens, and more than 100 scalars. Lexical evidence—not this shape
validator—decides whether a spelling exists.

The server-side generator is the single source for the Swift, Go, Python,
contract, and fixture artifacts. Client tests verify their digests and compile
the Swift runtime against the shared fixture. The full 149,400-spelling audit
reports zero normalized-key or ID changes, and every study/preparation target
passes the resolver shape.

The final content/API architecture is governed by the
[Entry-first technical design](ENTRY_FIRST_TECHNICAL_DESIGN.md). After
versioned Unicode and punctuation normalization, one exact spelling resolves
directly to one `WordEntry`. That entry contains every reviewed common
`UsageLesson` selected for the learner; context may reorder those lessons but
does not hide them. Supported forms such as `went`, `children`, and
`gynecologists` therefore have their own complete entries instead of requiring
the app to stem them or navigate through a client-side lemma/sense graph.

Each usage is a complete, concise teacher-style lesson rather than a rewritten
dictionary fragment: a direct explanation covering the necessary concept and
ordinary use, one natural example using the encountered spelling, optional
precise synonyms, and at most one evidence-backed memory cue. The title is
already visible, so the explanation begins with the concept itself. The cue is
rendered last, and structured emphasis may highlight verified word parts
without storing generated Markdown.

### Public Entry contract and private linguistic evidence

The implemented read-only SQLite catalog, writable overlay, Swift DTOs, and public
API expose only the learner-ready Entry contract. `entryID` and `entryUsageID`
are opaque registry keys; `explanationID` is a content-addressed key. None
carries linguistic meaning. The remaining public metadata is limited to exact
normalized/display spelling, lesson order,
content and compatibility versions, review trust, coverage, pronunciation or
other presentation/ranking data, and the lesson itself. The client treats the
opaque IDs as cache, selection, feedback, and replacement keys; it never
derives linguistic meaning from them.

Lemmas, parts of speech as identities, source senses, form analyses,
morphology, cross-form relationships, source provenance, teaching briefs, and
brief/lesson reviews remain private build-time and server data. Those systems
still need the full linguistic graph to establish facts such as `went` being a
past form of `go`, `children` being the plural of `child`, or the two readings
of `read`. The release builder compiles that evidence into flat, reviewed
Entries and strips the graph from the app artifact and public response. A
learner-facing label may be supplied as presentation content, but the client
does not use it to resolve a word.

Public explanation content lives in the bundled, read-only
`wordbook-content.sqlite`; personal cards, schedules, and answer history remain
in Core Data/CloudKit. A separate writable overlay at
`Library/Application Support/Wordbook/wordbook-entry-overlay.sqlite` stores complete
validated server Entries or immutable lesson variants, selections, pending
jobs, finite negative results, and an idempotent feedback outbox. It never
copies, attaches, migrates, or modifies the bundled database, so a versioned
content release can replace the active public catalog without moving it through
the user's CloudKit store.

`entryRevision` is the revision of one complete immutable Entry snapshot, so
every snapshot change—including a changed coverage decision—must advance it.
`coverageRevision` advances if and only if the reviewed Usage membership,
order, commonness rank, core flag, or declared counts/policy change; ordinary
lesson or presentation changes leave it unchanged. Durable server job IDs are
likewise bound to one immutable lookup/operation identity; retries may update
scheduling state without rebinding the job to another word or feedback event.

Lookup is strictly local-first:

1. Normalize the encountered spelling and read the complete candidate Entry
   snapshots from the writable overlay and active read-only SQLite catalog.
2. Validate their catalog lineage and revisions, then select one whole
   compatible snapshot. An overlay-only rare Entry needs no catalog row; an
   incompatible or stale overlay can never replace individual fields in a
   catalog Entry.
3. A complete local hit returns immediately with zero explanation-network
   requests and zero language-model inference.
4. In the production design, only an unknown Entry reaches the service. The server verifies the spelling
   and linguistic evidence, returns a correction or bounded negative result
   when appropriate, or runs one idempotent generation and independent-review
   job. A successful complete Entry is cached locally for later offline use,
   retained server-side, and becomes eligible for a future versioned content pack.

Requests for the same normalized spelling and operation share one in-flight or
durable job, so retries never create a generation loop. The phone does not
generate routine definitions and does not receive the private linguistic graph
or teaching briefs from the API. Legacy schema-v1 tooling and the singular `/v2`
endpoint remain compatibility rails for already-supported old app builds until
the coordinated Entry-first cutover; they do not define the new contract and
the new client does not fall back to their dictionary-shaped content.

### Feedback and replacement semantics

Explanation feedback is separate from `GOOD`, `VAGUE`, and `NOIDEA`, which continue to measure the learner's familiarity with the word. `Helpful` sends a like for the whole explanation and never asks for generation. The current `Explanation not helpful` and `Memory tip not helpful` actions send a dislike for that component and request exactly one replacement.

Every feedback event identifies the exact displayed `entryID`, `entryUsageID`,
and `explanationID`, plus its rating, component, and replacement intent. It
receives one UUID before delivery and is written to the overlay outbox first. A
versioned outbox envelope also retains the complete validated Entry snapshot
that was displayed. A retry therefore uses that same base even after a catalog
or selected replacement changes; it never silently binds the old feedback to
new content. Reusing an event UUID with a different full envelope is rejected.
This makes delivery idempotent and prevents a network retry from starting
another replacement generation. The server maps the opaque Entry identities
back to its private linguistic evidence.

The displayed explanation remains visible while a request is queued or
pending. A replacement is accepted only when it is a complete, independently
reviewed variant for the same `entryUsageID` with a new immutable explanation
identity; it is then selected in the overlay without altering either the old
variant or the bundled pack. Invalid or structurally inconsistent receipts are
rejected and remain pending for diagnosis rather than being reported as saved.
The app makes at most one immediate delivery attempt per tap and one bounded
outbox pass per process; neither path recursively drains the queue or requests
another replacement.

### Local language model role

Wordbook bundles a text-only 4-bit build of
[Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B) using
[MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) with XGrammar-backed
guided generation. Under the final Entry-first architecture, this local model
is reserved for comprehension assessment—for example, comparing a learner's
own explanation with the selected lesson—not for routine definition
generation. Entry lookup and explanation prefetch never wait for this model,
and its loading or warm-up does not gate normal app readiness. A future
assessment fallback may use the server when the local evaluator cannot reach a
reliable result, but model output never directly changes grades, intervals, or
due dates.

The model payload in `LocalModels/Qwen3.5-2B-4bit-text/` is 1,059,405,152 bytes. It is derived from `mlx-community/Qwen3.5-2B-4bit` revision `674aaa7240b91e8012fcad5d791b7dfe5ba90207`; 297 unused `vision_tower.*` tensors were removed and all 694 `language_model.*` tensors were retained. `manifest.json` records provenance, byte sizes, and SHA-256 hashes. The model is Apache-2.0 licensed and its license ships beside it.

The 1 GiB `model.safetensors` payload is deliberately not stored in Git. Prepare it after cloning and before building:

```sh
python3 scripts/setup_local_model.py
```

The standard-library-only setup script downloads from the pinned Hugging Face revision, reconstructs the text-only model, verifies its exact 1,059,405,152-byte size and SHA-256 `b93b36a825ff36ef68eb4249295ac24942e15d67794e9747961e1640fe8a9b39`, and installs it atomically. This is a developer setup download; the built app bundles the verified model. The iOS target pins `mlx-swift-lm` revision `38927f5f3da6d4720ac952f4d97f88d4424f11aa`, MLX Swift 0.31.6, and Swift Transformers 1.3.0. Building MLX for a physical device requires Xcode's optional Metal Toolchain.

### Developer content-pack setup

`Shared/wordbook-content.sqlite` is generated release content and is intentionally ignored by Git.

For a published Entry-first release, prefer its signed manifest. The
`allowed_signers` file is an independently provisioned trust root; never use a
public key downloaded beside the manifest:

```sh
python3 scripts/install_signed_content_release.py \
  --manifest-url "$PUBLISHED_CONTENT_MANIFEST_HTTPS_URL" \
  --signature-url "$PUBLISHED_CONTENT_SIGNATURE_HTTPS_URL" \
  --allowed-signers /secure/wordbook-content-allowed-signers \
  --app-build 209
```

This is release/build installation tooling for the SQLite resource bundled in
the next app build; the shipped app does not yet download full signed catalog
updates at runtime. The installer verifies the byte-canonical manifest with
OpenSSH SSHSIG Ed25519 namespace `wordbook-content-release-v1` before trusting
its artifact URL, hashes, exact byte size, minimum app build, or content
contracts. It then requires the pinned production DDL, SQLite integrity and
foreign keys, exact metadata, runtime-readable JSON, complete Entry coverage,
immutable lesson hashes, and a manifest-to-pack match.

After successful activation, the installer atomically writes
`Shared/.wordbook-content-build-receipt.json`. That ignored receipt binds the
exact SQLite SHA-256, byte size, content version, contracts, counts, signed
manifest digest, release sequence, and signing-key identity used by the
Release build. The iOS application target runs
`scripts/validate_release_content_pack.py` before copying resources in every
Release build, including Mac Catalyst and Archive. The gate opens the database
read-only, checks SQLite integrity and foreign keys, checks schema-2 metadata,
and matches the pack to the receipt. It always rejects the seven-Entry golden
fixture. Debug and test builds do not run this production gate.

CI may set `WORDBOOK_CONTENT_BUILD_RECEIPT_PATH` to another installer-produced
receipt. Direct use of the validator without a receipt requires all six exact
expectation variables: `WORDBOOK_CONTENT_EXPECTED_SHA256`,
`WORDBOOK_CONTENT_EXPECTED_CONTENT_VERSION`,
`WORDBOOK_CONTENT_EXPECTED_ENTRY_COUNT`,
`WORDBOOK_CONTENT_EXPECTED_USAGE_COUNT`,
`WORDBOOK_CONTENT_EXPECTED_EXPLANATION_COUNT`, and
`WORDBOOK_CONTENT_EXPECTED_MINIMUM_APP_BUILD`.

The installer persists a release sequence and the highest sequence ever
accepted, so an older or superseded release cannot be replayed while that
ledger is retained. Release automation must place `--state-path` and its
pending receipt in durable, access-controlled storage and restore them before
each run; deleting the ledger turns the next run into a fresh installation. A deliberate
rollback must name the active sequence and be signed by a separately
provisioned key passed with `--rollback-key-id`; rollback never lowers the
high-water mark. The previous valid SQLite remains at
`Shared/.wordbook-content.previous.sqlite`. A durable pending receipt closes
the pack/state rename crash window and is reconciled on the next invocation.
The generated state, build receipt, and recovery files are ignored by Git.

The three locations and build number can instead be supplied through
`WORDBOOK_CONTENT_MANIFEST_URL`, `WORDBOOK_CONTENT_SIGNATURE_URL`, and
`WORDBOOK_CONTENT_ALLOWED_SIGNERS`, and `WORDBOOK_APP_BUILD`. Comma-separated
rollback key IDs may be supplied through
`WORDBOOK_CONTENT_ROLLBACK_KEY_IDS`.

For a local or manually pinned artifact, use the lower-level installer:

```sh
python3 scripts/install_content_pack.py \
  --source "$LOCAL_CONTENT_PACK" \
  --sha256 "$PUBLISHED_CONTENT_PACK_SHA256"
```

The same installer can fetch a published artifact from an absolute HTTPS URL. Supply both the URL and its published digest either as flags:

```sh
python3 scripts/install_content_pack.py \
  --url "$PUBLISHED_CONTENT_PACK_HTTPS_URL" \
  --sha256 "$PUBLISHED_CONTENT_PACK_SHA256"
```

or as environment variables:

```sh
WORDBOOK_CONTENT_URL="$PUBLISHED_CONTENT_PACK_HTTPS_URL" \
WORDBOOK_CONTENT_SHA256="$PUBLISHED_CONTENT_PACK_SHA256" \
python3 scripts/install_content_pack.py
```

For a local artifact, `WORDBOOK_CONTENT_SOURCE` can replace `WORDBOOK_CONTENT_URL`. The installer accepts exactly one source, requires a 64-character SHA-256, rejects SQLite sidecars, verifies the digest, SQLite application ID, schema version, required tables, and full `integrity_check`, then atomically replaces the ignored destination. No unpinned download is accepted. The Xcode project packages this stable path in the shared iOS/iPadOS/Mac Catalyst application target as a read-only resource; a build therefore requires the setup step after a fresh clone. It is deliberately excluded from the Watch and extension bundles.

### Discovery, extensions, and future comprehension checks

The Wikipedia summary card and the `news`, `images`, `web`, and `translate` buttons remain beneath the main explanation. They are optional discovery features and never supply or replace it. Vocabulary.com remains removed. Autocomplete, spelling aliases, random words, and COCA/BASIC/TOEFL/SAT/GRE selection continue to use the 4.82 MiB memory-mapped `Shared/lexical-index.wbli`, which contains spellings and book membership but no definitions.

Watch and Share extensions do not load the local language model. The Share
extension queues words for the phone. The phone sends the Watch bounded,
validated snapshots of complete learner-ready Entries that are already
available in its catalog or overlay. The Watch keeps up to 32 whole Entries in
a 48 KiB offline cache; it rejects an oversized or partial Entry instead of
dropping reviewed Usages. It does not receive the private linguistic graph,
carry the SQLite catalog, contact the explanation service, or perform
definition generation.

The long-term role of LocalTutor is comprehension assessment rather than
routine definition generation. A future quiz can ask the learner for a typed
explanation—or text transcribed by a separate speech-recognition component—and
compare it with the selected `entryUsageID` lesson under a dedicated assessment
contract on-device. A bounded server fallback may handle an assessment that
cannot return a reliable local result. This evaluator remains separate from
explanation display and from the deterministic study engine: model output must
never directly mutate grades, intervals, or due dates.
