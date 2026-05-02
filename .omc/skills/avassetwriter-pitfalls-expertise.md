---
name: avassetwriter-pitfalls
description: AVAssetWriter silent-failure modes — HE-AAC encoder rejection of mono PCM ("Cannot Encode Media") and session-anchor mismatch causing duration=0 in finished MP4
triggers:
  - "AVAssetWriterInput.append returned false"
  - "Cannot Encode Media"
  - "writer.status == .failed"
  - kAudioFormatMPEG4AAC_HE
  - HE-AAC
  - "kMDItemDurationSeconds = 0"
  - "0-byte segments"
  - mp4 plays one frame stops
  - SegmentWriter
  - ScreenRecorder duration zero
  - "startSession atSourceTime"
---

# AVAssetWriter — Two Silent Failure Modes

## The Insight

`AVAssetWriter` and its inputs report failures asynchronously and silently. A successful `startWriting()` plus a successful `addInput()` do not mean encoding will succeed when the first sample arrives. Two specific gotchas waste hours if you don't know them:

1. **HE-AAC (`kAudioFormatMPEG4AAC_HE`) rejects our mono Float32 48 kHz PCM** with "Cannot Encode Media". `canAdd(input)` and `startWriting()` both return true, but the very first `AVAssetWriterInput.append(sampleBuffer)` returns `false` and `writer.status` flips to `.failed`. Every subsequent `append` returns false too, with no further diagnostics. You only notice when `finishWriting()` returns and your output file is missing or zero bytes.

2. **`startSession(atSourceTime:)` with mach-time PTS while feeding rebased samples** produces an MP4 that has all your video frames inside but reports `kMDItemDurationSeconds = 0`. AVPlayer loads it, paints the first frame, and the play button does nothing — it thinks duration is zero so there's nowhere to go.

## Why This Matters

**HE-AAC**: macOS's "Storage Profile" tier defaulted JarvisNote's recordings to HE-AAC for 50% size savings vs AAC-LC. SegmentWriter created the writer, opened inputs (canAdd → true), called `startWriting()` (returned true), then on every PCM buffer the encoder failed silently. Result: a 60-minute meeting recorded zero usable seconds. The user reported "No audio captured" but the bug was three layers deep — the original error message ("check Microphone permission") was misleading because mic permission was actually granted and buffers WERE flowing into AudioEngine; they just couldn't survive the encoder.

**Session anchor**: When ScreenRecorder rebases video sample PTS to `.zero` (subtracting `firstSampleTime`) but anchors the writer session at the *original* `firstSampleTime` (mach-time, ~44000 seconds), every appended frame sits **before** the session's start time. AVAssetWriter accepts the appends without complaint — they go into the file's data — but the file's duration metadata reads zero because nothing fits inside the session window. Player picks up the file, sees duration=0, plays nothing.

Both bugs share a pattern: AVAssetWriter doesn't validate the timing/format invariants you'd expect; it accepts data that's logically impossible and produces a broken file.

## Recognition Pattern

**HE-AAC trigger** — when ALL true:
- `audioFormatID` in your output settings is `kAudioFormatMPEG4AAC_HE` (decimal 1633772392, FourCC 'aach')
- `AVAssetWriterInput.append(_:)` returns false on first call
- `writer.status.rawValue == 3` (`.failed`)
- `writer.error?.localizedDescription` contains "Cannot Encode Media"

**Session anchor trigger** — when ALL true:
- Your code does `writer.startSession(atSourceTime: firstPTS)` with `firstPTS` from `CMSampleBufferGetPresentationTimeStamp` (mach time)
- Your code then appends samples with `pixelBufferAdaptor.append(buf, withPresentationTime: CMTimeSubtract(pts, firstPTS))` (rebased to .zero)
- Output `.mp4` plays first frame but Play button is dead
- `mdls -name kMDItemDurationSeconds output.mp4` returns 0
- Frame count is non-zero (you can confirm via `ffprobe -count_frames` or our own logged "framesWritten=N")

## The Approach

**Make silent failures loud first, then fix.** The pattern that worked for both bugs was identical:

1. Add `os.Logger` at every layer of the AVAssetWriter pipeline. Log:
   - `openSegment`: format ID, sample rate, bitrate, output URL
   - `startWriting()` return value AND `writer.status` AND `writer.error?.localizedDescription`
   - Every `append` failure with status + error
   - `finishWriting()` final status + frame counts
2. Run a real recording and read `log show --predicate 'subsystem == "your.subsystem"'` — the failing layer becomes obvious in seconds rather than hours.

**For HE-AAC specifically**: don't use it. Use plain `kAudioFormatMPEG4AAC` (AAC-LC) for mono speech. The 50% size saving is real for music but for voice at 48 kbps the difference is marginal and the encoder is reliable. If you want HE-AAC, validate it works with your specific PCM ASBD on your specific macOS version before shipping it as default. JarvisNote's `applyStorageProfile()` for `.balanced` and the codec migration in `AppSettings.init()` both rewrite stored `audioCodec=.heAAC` to `.aac`.

**For session anchor**: pick one timeline and stick with it. Either:
- Anchor at `pts` AND append with `pts` (no rebasing) — final file's PTS reflects mach time
- OR anchor at `.zero` AND append with `pts - firstPTS` (rebasing) — final file starts at 0

Mixing them produces duration=0. We chose `.zero` anchor since it's simpler and produces files that play correctly in QuickTime/AVPlayer.

## Diagnostic Recipes

```swift
// In SegmentWriter.openNewSegment
let started = writer.startWriting()
if !started || writer.status != .writing {
    log.error("startWriting returned \(started) status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil")")
}

// In appendBuffer
let appended = input.append(sampleBuffer)
if !appended {
    log.error("append returned false — status=\(self.assetWriter?.status.rawValue ?? -1) error=\(self.assetWriter?.error?.localizedDescription ?? "nil")")
}

// In finalizeCurrentSegment
if writer.status != .completed {
    log.error("finalize idx=\(idx) status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil")")
}
```

```sh
# Decode FourCC from numeric format ID
python3 -c "import struct; print(struct.pack('>I', 1633772392).decode())"
# → 'aach' (HE-AAC v1)

# Verify .mp4 duration metadata
mdls -name kMDItemDurationSeconds -name kMDItemPixelWidth output.mp4
```

## Anti-patterns

- **Don't trust `try?` around `writer.append` / `screenRecorder?.stop()` calls**: silent error swallowing turned a 5-minute encoder bug into a 2-hour debugging session. Replace `try?` with `do/catch + os.Logger.error`.
- **Don't assume canAdd + startWriting = encoding will work**: those check setup, not encoding. The failure is at first `append`.
- **Don't rely on the file existing as proof of success**: a failed writer can leave a non-zero-byte but unreadable .mp4. Always check `writer.status == .completed` after `finishWriting()`.
