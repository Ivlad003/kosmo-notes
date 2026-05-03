@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation

// MARK: - AudioInputDevice

/// One Core Audio input device discoverable via `AudioDeviceEnumerator`.
///
/// Used by Settings → "System audio source" picker to let the user route
/// capture through a virtual loopback device (e.g. BlackHole 2ch) instead of
/// SCKit's whole-system mixdown — eliminates the speaker → mic echo loop
/// when recording mic + system audio without headphones.
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    /// Core Audio device ID (`AudioDeviceID`). Stable for the device's lifetime
    /// in this boot but NOT across reboots — persist `uid` instead.
    public let id: AudioDeviceID
    /// Human-friendly name (e.g. "MacBook Pro Microphone", "BlackHole 2ch").
    public let name: String
    /// Persistent device UID — survives reboot, used as the saved settings key.
    public let uid: String
    /// True if name matches a known virtual-loopback driver (BlackHole, Soundflower,
    /// Loopback). UI uses this to nudge the user toward the right pick.
    public let isVirtualLoopback: Bool

    public init(id: AudioDeviceID, name: String, uid: String, isVirtualLoopback: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.isVirtualLoopback = isVirtualLoopback
    }
}

// MARK: - AudioDeviceEnumerator

/// Read-only Core Audio HAL discovery. List input devices that have at least
/// one input stream — that excludes pure output devices like built-in speakers.
public enum AudioDeviceEnumerator {

    /// All input-capable devices currently visible to the system.
    public static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioInputDevice? in
            guard hasInputStreams(deviceID: id) else { return nil }
            guard let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName) else { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let virtual = isVirtualLoopback(name: name)
            return AudioInputDevice(id: id, name: name, uid: uid, isVirtualLoopback: virtual)
        }
        .sorted { lhs, rhs in
            // Virtual loopback devices (BlackHole etc) bubble to the top.
            if lhs.isVirtualLoopback != rhs.isVirtualLoopback {
                return lhs.isVirtualLoopback
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Look up an `AudioDeviceID` from a persistent UID. nil if the device is
    /// not currently plugged in / available.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first(where: { $0.uid == uid })?.id
    }

    // MARK: - Private helpers

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard status == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains(where: { $0.mNumberChannels > 0 })
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var cfString: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(dataSize)) { _ in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
            }
        }
        guard status == noErr, let value = cfString?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func isVirtualLoopback(name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("blackhole")
            || lower.contains("soundflower")
            || lower.contains("loopback")
            || lower.contains("ladiocast")
    }
}
