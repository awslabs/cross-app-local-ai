import AudioToolbox
import CoreAudio
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "audio.devices")

// MARK: - AudioInputDevice

/// A microphone or other audio input device discovered via Core Audio.
struct AudioInputDevice: Identifiable, Equatable {
    /// Transient system identifier (changes across reboots).
    let deviceID: AudioDeviceID
    /// Persistent unique identifier suitable for config storage.
    let uid: String
    /// Human-readable device name (e.g. "MacBook Pro Microphone").
    let name: String

    var id: String {
        uid
    }
}

// MARK: - AudioDeviceEnumerator

/// Enumerates macOS audio input devices using Core Audio's HAL.
///
/// All methods are static and synchronous -- Core Audio's property queries
/// are non-blocking. The enumerator is intentionally stateless; callers
/// should re-enumerate on each settings view appearance to pick up
/// hot-plugged devices.
enum AudioDeviceEnumerator {

    /// Lists all audio devices that have at least one input stream.
    ///
    /// - Returns: Input devices sorted by name, built-in devices first.
    static func inputDevices() -> [AudioInputDevice] {
        let allDeviceIDs = allDeviceIDs()
        var devices: [AudioInputDevice] = []

        for deviceID in allDeviceIDs {
            guard hasInputStreams(deviceID: deviceID) else { continue }
            guard let name = deviceName(deviceID: deviceID),
                  let uid = deviceUID(deviceID: deviceID)
            else { continue }

            devices.append(AudioInputDevice(
                deviceID: deviceID,
                uid: uid,
                name: name
            ))
        }

        devices.sort { lhs, rhs in
            let lhsBuiltIn = lhs.uid.contains("BuiltIn")
            let rhsBuiltIn = rhs.uid.contains("BuiltIn")
            if lhsBuiltIn != rhsBuiltIn { return lhsBuiltIn }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        logger.debug("Enumerated \(devices.count) input device(s)")
        return devices
    }

    /// Returns the system default input device ID, or `nil` if unavailable.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Resolves a persistent device UID to a transient `AudioDeviceID`.
    ///
    /// - Parameter uid: The persistent UID string stored in config.
    /// - Returns: The matching device ID, or `nil` if the device is not connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            &cfUID,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            logger.warning("Failed to resolve device UID '\(uid)': status \(status)")
            return nil
        }
        return deviceID
    }

    // MARK: - Private Helpers

    private static func allDeviceIDs() -> [AudioDeviceID] {
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
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return nil }
        return cfName as String
    }

    private static func deviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard status == noErr, let cfUID = uid?.takeRetainedValue() else { return nil }
        return cfUID as String
    }
}
