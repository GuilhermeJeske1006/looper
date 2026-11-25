import CoreAudio
import Foundation

/// A real Core Audio device. `uid` is persistent across sessions; `objectID` is not.
public struct AudioDevice: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let objectID: AudioDeviceID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double

    public init(objectID: AudioDeviceID, uid: String, name: String, manufacturer: String,
                inputChannels: Int, outputChannels: Int, nominalSampleRate: Double) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.nominalSampleRate = nominalSampleRate
    }

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    /// The CK61/CK88 shows up as "CK Series" (Yamaha Corporation) over USB TO HOST.
    public var isYamahaCK: Bool {
        let n = name.lowercased()
        return n.contains("ck series") || n.contains("ck61") || n.contains("ck88")
    }

    public var isYamaha: Bool { manufacturer.lowercased().contains("yamaha") }
}

public enum AudioHardware {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Every visible device currently known to Core Audio.
    public static func devices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device(objectID: $0) }
    }

    public static func device(objectID: AudioDeviceID) -> AudioDevice? {
        guard let uid = string(objectID, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
        if uint32(objectID, kAudioDevicePropertyIsHidden) == 1 { return nil }
        return AudioDevice(
            objectID: objectID,
            uid: uid,
            name: string(objectID, kAudioObjectPropertyName) ?? uid,
            manufacturer: string(objectID, kAudioObjectPropertyManufacturer) ?? "",
            inputChannels: channelCount(objectID, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(objectID, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: float64(objectID, kAudioDevicePropertyNominalSampleRate) ?? 0
        )
    }

    public static func isAlive(_ id: AudioDeviceID) -> Bool {
        uint32(id, kAudioDevicePropertyDeviceIsAlive) == 1
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr,
              id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    // MARK: Property helpers

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func float64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var addr = address(selector)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Calls `onChange` (on `queue`) whenever devices are connected or disconnected.
public final class AudioDeviceWatcher {
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var addr = AudioHardware.address(kAudioHardwarePropertyDevices)

    public init(queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.queue = queue
        self.block = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioHardware.systemObject, &addr, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioHardware.systemObject, &addr, queue, block)
    }
}
