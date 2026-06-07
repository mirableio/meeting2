import CoreAudio
import Foundation

// Test-only Core Audio utility. The recorder must survive output-route changes,
// but route switching is an OS-level operation, not recorder behavior. Keeping it
// in a separate executable lets Makefile gates exercise route changes without
// giving the capture core any code path that mutates the user's audio settings.
struct AudioDevice: Equatable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let outputChannels: UInt32
}

enum ToolError: Error, CustomStringConvertible {
    case coreAudio(OSStatus, String)
    case invalidArgument(String)
    case noOutputDevices
    case deviceNotFound(String)

    var description: String {
        switch self {
        case let .coreAudio(status, operation):
            return "\(operation) failed with OSStatus \(status)"
        case let .invalidArgument(message):
            return message
        case .noOutputDevices:
            return "No output devices found"
        case let .deviceNotFound(query):
            return "No output device matched '\(query)'"
        }
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw ToolError.coreAudio(status, operation)
        }
    }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

func readObjectID(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> AudioObjectID {
    var address = propertyAddress(selector)
    var value = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try ToolError.check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
        "AudioObjectGetPropertyData(\(selector))"
    )
    return value
}

func readString(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try ToolError.check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
        "AudioObjectGetPropertyData(string \(selector))"
    )

    guard let value else {
        return ""
    }

    return value.takeRetainedValue() as String
}

func outputChannelCount(_ objectID: AudioObjectID) throws -> UInt32 {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    try ToolError.check(
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(stream configuration)"
    )

    // AudioBufferList is variable-length, so there is no safe fixed Swift struct
    // to read here. Allocate exactly the HAL-reported byte size, then wrap it in
    // UnsafeMutableAudioBufferListPointer for typed iteration.
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }

    try ToolError.check(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw),
        "AudioObjectGetPropertyData(stream configuration)"
    )

    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(UInt32(0)) { partial, buffer in
        partial + buffer.mNumberChannels
    }
}

func allOutputDevices() throws -> [AudioDevice] {
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try ToolError.check(
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(devices)"
    )

    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    try ids.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            throw ToolError.noOutputDevices
        }
        try ToolError.check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, baseAddress),
            "AudioObjectGetPropertyData(devices)"
        )
    }

    return try ids.compactMap { id in
        let channels = try outputChannelCount(id)
        guard channels > 0 else { return nil }
        return AudioDevice(
            id: id,
            name: try readString(id, selector: kAudioDevicePropertyDeviceNameCFString),
            uid: try readString(id, selector: kAudioDevicePropertyDeviceUID),
            outputChannels: channels
        )
    }
}

func currentOutputDevice() throws -> AudioDevice {
    let id = try readObjectID(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
    guard let device = try allOutputDevices().first(where: { $0.id == id }) else {
        throw ToolError.noOutputDevices
    }
    return device
}

func matchOutputDevice(_ query: String) throws -> AudioDevice {
    let devices = try allOutputDevices()
    guard let device = devices.first(where: { $0.uid == query || $0.name == query }) else {
        throw ToolError.deviceNotFound(query)
    }
    return device
}

func firstOtherOutputDevice(currentUID: String) throws -> AudioDevice {
    guard let device = try allOutputDevices().first(where: { $0.uid != currentUID }) else {
        throw ToolError.noOutputDevices
    }
    return device
}

func setDefaultOutput(_ device: AudioDevice) throws {
    var outputAddress = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var systemAddress = propertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
    var id = device.id
    let size = UInt32(MemoryLayout<AudioObjectID>.size)

    // Set both default-output selectors. Some apps follow DefaultOutputDevice;
    // system sounds use DefaultSystemOutputDevice. The route-change gate needs
    // both to move so the test is representative of real meeting audio.
    try ToolError.check(
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, size, &id),
        "AudioObjectSetPropertyData(default output)"
    )
    try ToolError.check(
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &systemAddress, 0, nil, size, &id),
        "AudioObjectSetPropertyData(default system output)"
    )
}

let help = """
Usage:
  AudioDeviceTool list-output
  AudioDeviceTool current-output-uid
  AudioDeviceTool current-output-name
  AudioDeviceTool first-other-output-uid <current-uid>
  AudioDeviceTool set-output <uid-or-exact-name>
"""

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw ToolError.invalidArgument(help)
    }

    switch command {
    case "list-output":
        for device in try allOutputDevices() {
            print("\(device.uid)\t\(device.name)\t\(device.outputChannels)ch")
        }
    case "current-output-uid":
        print(try currentOutputDevice().uid)
    case "current-output-name":
        print(try currentOutputDevice().name)
    case "first-other-output-uid":
        guard args.count == 2 else { throw ToolError.invalidArgument(help) }
        print(try firstOtherOutputDevice(currentUID: args[1]).uid)
    case "set-output":
        guard args.count == 2 else { throw ToolError.invalidArgument(help) }
        try setDefaultOutput(try matchOutputDevice(args[1]))
    default:
        throw ToolError.invalidArgument(help)
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
