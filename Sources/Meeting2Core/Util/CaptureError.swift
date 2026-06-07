import Foundation

// Capture failures, as plain values with human-readable messages. They are
// intentionally just strings, not a logging framework: the recording path must stay
// free of dependencies on UI, storage, or logging (anything heavier is one more thing
// that can fail mid-meeting). `coreAudio` carries the raw OSStatus so a HAL failure
// can be looked up; the rest describe a specific precondition that wasn't met.
public enum CaptureError: Error, CustomStringConvertible {
    case coreAudio(OSStatus, String)
    case unsupportedFormat(String)
    case invalidState(String)
    case conversionFailed(String)
    case unknownTapObject
    case unknownAggregateObject

    public var description: String {
        switch self {
        case let .coreAudio(status, operation):
            return "\(operation) failed: \(Self.fourCharacterCode(status)) (\(status))"
        case let .unsupportedFormat(message):
            return "Unsupported format: \(message)"
        case let .invalidState(message):
            return "Invalid state: \(message)"
        case let .conversionFailed(message):
            return "Conversion failed: \(message)"
        case .unknownTapObject:
            return "Invalid state: Process tap returned unknown object ID"
        case .unknownAggregateObject:
            return "Invalid state: Aggregate device returned unknown object ID"
        }
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CaptureError.coreAudio(status, operation)
        }
    }

    private static func fourCharacterCode(_ status: OSStatus) -> String {
        // Many Core Audio OSStatus values are four-character codes. Printing both
        // the symbolic-looking code and integer form makes HAL failures searchable.
        let value = UInt32(bitPattern: status)
        let scalars = [
            UnicodeScalar((value >> 24) & 0xff),
            UnicodeScalar((value >> 16) & 0xff),
            UnicodeScalar((value >> 8) & 0xff),
            UnicodeScalar(value & 0xff)
        ]

        let string = String(String.UnicodeScalarView(scalars.compactMap { scalar in
            guard let scalar, scalar.value >= 32, scalar.value <= 126 else { return nil }
            return scalar
        }))

        return string.count == 4 ? string : "????"
    }
}
