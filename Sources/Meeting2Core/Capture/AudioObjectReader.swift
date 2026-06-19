import CoreAudio
import Foundation

// Small typed helpers for reading Core Audio properties. Core Audio exposes almost
// everything (device formats, IDs, names) through one weakly-typed C function where you
// pass a property selector and a byte buffer of the right size — easy to get wrong. Each
// helper here wraps exactly one property read with the correct sizing and memory rules
// (e.g. string properties hand back a retained object that must be released), and we
// keep them narrow on purpose rather than one clever generic that hides those rules.
enum AudioObjectReader {
    static func readAudioObjectID(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try CaptureError.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            "AudioObjectGetPropertyData(AudioObjectID \(selector))"
        )
        return value
    }

    static func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try CaptureError.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            "AudioObjectGetPropertyData(UInt32 \(selector))"
        )
        return value
    }

    static func readStreamDescription(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CaptureError.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            "AudioObjectGetPropertyData(\(selector))"
        )
        return value
    }

    static func readCFString(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // HAL returns retained CF objects for string properties. Model that
        // explicitly with Unmanaged so ARC ownership is obvious at the call site.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try CaptureError.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            "AudioObjectGetPropertyData(CFString \(selector))"
        )

        guard let value else {
            throw CaptureError.invalidState("Missing CFString property \(selector)")
        }

        return value.takeRetainedValue() as String
    }
}
