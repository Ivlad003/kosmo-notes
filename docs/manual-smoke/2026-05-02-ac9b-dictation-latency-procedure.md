# AC-9b — Dictation Mode end-to-end latency: manual measurement procedure

Owner: release manager
When to run: once, immediately before tagging v1.0
Output: a filled-in table attached to the v1.0 release notes (per §10 item 8 of the implementation plan)

## 1. What you're measuring

Frame-count from the moment the dictation hotkey is **released** to the moment cleaned text is **visible in the focused field**. Captured with QuickTime 60-fps screen recording so each frame equals 16.67 ms. End-to-end. Includes Whisper round-trip, optional LLM cleanup, and the AX paste.

The spec target is **median ≤ 1.5 s** across 5 trials of a 10-second utterance on a 50 Mbps connection with Anthropic LLM cleanup enabled.

## 2. Pre-conditions (must hold before starting)

- macOS 14.5+, Apple Silicon
- Uplink ≥ 50 Mbps. Verify with fast.com or Speedtest **immediately** before recording the trials, not yesterday.
- Anthropic and OpenAI API keys configured in Settings → AI Providers (test connection green for both)
- `dictationLLMCleanup` enabled in Settings → Dictation
- Accessibility permission granted to Jarvis Note in System Settings → Privacy & Security → Accessibility. **Relaunch Jarvis Note after granting** — AX trust does not take effect until the process is restarted.
- Focused text field in TextEdit (or any plain-text editor). **Do not measure into a sandboxed app** like the App Store version of Slack or Discord — those force the clipboard fallback in `AccessibilityPaster` and the resulting timing reflects clipboard paste, not the AX path. The "default" path is what we ship a latency claim against.

## 3. The procedure (5 trials)

For each of 5 trials, do this end-to-end:

1. Start QuickTime Player → File → New Screen Recording → set frame rate to **60 fps** → record full screen.
2. Open TextEdit, click into the document, confirm the cursor is blinking.
3. Hold ⌘⇧D and count out loud, in your normal cadence: "one banana, two banana, three banana, four banana, five banana, six banana, seven banana, eight banana." That is roughly 10 s of natural speech.
4. Release ⌘⇧D.
5. Wait until pasted text appears in TextEdit, then stop the QuickTime recording.
6. Open the QuickTime recording, scrub to the frame where ⌘⇧D releases. Pick a visual cue (cursor change, finger lift off the key — whichever you can see clearly) and **use the same cue for all 5 trials**. Note the frame number.
7. Scrub forward to the **first** frame where any pasted text is visible. Note that frame number.
8. Δ frames × (1/60 s) = latency in seconds.

## 4. Reporting format

Fill this table and paste it into the v1.0 release notes:

```
| Trial | Hotkey-release frame | Text-rendered frame | Δ frames | Latency (s) |
|-------|----------------------|---------------------|----------|-------------|
| 1     |                      |                     |          |             |
| 2     |                      |                     |          |             |
| 3     |                      |                     |          |             |
| 4     |                      |                     |          |             |
| 5     |                      |                     |          |             |
```

Also report, alongside the table:

- **Median** latency (s)
- **p95** latency (s)
- Network uplink measured pre-test (Mbps, source: fast.com or Speedtest)
- macOS version (e.g. 14.5)
- Hardware (e.g. MacBook Pro M3, 16 GB)
- Date of measurement

## 5. Pass / fail / disclose

- **Pass — median ≤ 1.5 s.** Attach the table to release notes and ship.
- **Soft fail — median 1.5–2.0 s.** Ship anyway. In the release notes, the latency claim line reads: *"Best-effort dictation latency, ≤2 s typical (measured p95: X.X s)."* Do **not** claim "<1.5 s".
- **Hard fail — median > 2.0 s.** Investigate before tagging. Likely culprits, in order:
  1. Slow uplink — re-test on a better connection before any code change.
  2. Whisper-batch transcription path is the dominant cost (see §6). Switching to Deepgram streaming with a PCM tee from `CaptureSession` would close the gap; that work is v1.1, not v1.0.

## 6. Known caveats (read before measuring)

- **v0 ships with Whisper batch transcription, not Deepgram streaming.** `CaptureSession` does not yet expose a PCM tee, so `DictationPipeline` finalises the audio segment after hotkey-release and uploads the whole 10-second clip in one batch request. Whisper batch round-trip on a 10-second utterance is typically the largest single contributor to the measured latency. The AC-9b 1.5 s target is **not expected to be met by the v0 architecture**. Record the measured number honestly — a future v1.1 with Deepgram streaming + PCM tee will close the gap; until then, the soft-fail wording in §5 is the realistic ship state.
- **LLM cleanup adds round-trip on top of transcription.** The "LLM cleanup off" path is faster. If the release manager wants to publish both numbers for comparison, run a second 5-trial pass with `dictationLLMCleanup` disabled and label those rows "(cleanup off)" in a second copy of the table.
- **Stick to one cue for hotkey-release across all 5 trials in a session.** Mixing "finger lift" on trials 1–2 with "cursor change" on trials 3–5 introduces noise larger than the inter-trial variance and makes the median meaningless.
