import CoreAudio
import Foundation

/// A microphone-class input device discovered via Core Audio HAL.
struct AudioInputDevice: Hashable, Identifiable {
    let id: AudioDeviceID
    let uid: String     // persistent across reboots and reconnects
    let name: String
}

/// Enumerate all input-capable audio devices on the system.
enum AudioInputs {

    static func list() -> [AudioInputDevice] {
        let allIDs = allDeviceIDs()
        return allIDs.compactMap { id in
            guard hasInputStreams(id) else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Look up an AudioDeviceID by UID. Returns nil if the device is not currently connected.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        list().first(where: { $0.uid == uid })?.id
    }

    /// Resolve the system's current default input device.
    static func systemDefault() -> AudioInputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        guard let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString) ?? "System default"
        return AudioInputDevice(id: deviceID, uid: uid, name: name)
    }

    // MARK: - Internals

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        )
        return status == noErr ? ids : []
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains(where: { $0.mNumberChannels > 0 })
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var stringRef: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &stringRef) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return stringRef as String
    }
}
