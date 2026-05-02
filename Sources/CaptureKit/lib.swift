// CaptureKit — Phase A Week 1 implementation.
// Provides: AudioEngine, AACEncoder, SegmentWriter, SCKitAudioCapture, CaptureSession.
//
// DEVIATION: Plan specified Opus encoding; this implementation uses AAC (kAudioFormatMPEG4AAC).
// Reason: AVAudioConverter Opus output requires macOS 14+; deployment target is macOS 12.3+.
// AAC is universally supported, plays in QuickTime natively, zero extra dependencies.
// Segment files are .m4a (MPEG-4 container). See AACEncoder.swift for full rationale.
