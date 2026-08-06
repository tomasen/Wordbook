# Wordbook FluidAudio patch

This directory vendors the `FluidAudio` library target from upstream release
`0.15.5` (`19600a48`) under its Apache-2.0 license. CLI, test, benchmark, and
documentation targets that Wordbook does not build are intentionally omitted.

Wordbook replaces Kokoro's final dynamic-shape `KokoroTail.mlmodelc`
prediction with an equivalent native Accelerate implementation. On an iPhone
Air running iOS 26.6, changing Tail input length from 7,081 to 7,561 caused
Apple's E5RT/BNNS runtime to reuse an undersized internal scratch allocation
and terminate the process with `EXC_BAD_ACCESS`. Swift cannot catch that native
fault.

`KokoroAneNativeTail.swift` validates and reads the four Float32 blobs from the
bundled Tail weight file, then performs the graph's Conv1D, magnitude/phase,
transposed-convolution, subtraction, and crop using Accelerate. Its output was
compared with the original Core ML graph at the failing length and differed by
less than `5e-7` per sample. Normal initialization now loads six Core ML models
plus this native Tail instead of loading the unsafe seventh model.

The integrated app was then exercised on the same iPhone Air with a warm-up
followed by ten cycles of `silica`, `ready`, `caudate`, `fecund`, `covet`, and
`lapidary`. All 60 varying-length syntheses returned valid WAV data without a
process crash. This is a runtime-safety check, not a subjective voice-quality
test.

The vendored source also includes FluidAudio's later non-finite PostAlbert
duration guard (`26104591`), so a malformed Core ML output becomes a catchable
error instead of trapping during `Float`-to-`Int32` conversion.

Keep the upstream `LICENSE` and `ThirdPartyLicenses` directory when updating
this vendored package. Reapply and revalidate the Wordbook Tail changes against
the new upstream version before replacing these sources.
