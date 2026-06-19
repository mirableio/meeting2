import CoreAudio
import Foundation

/// Where the Mac was sending audio when a recording began — captured once at start and
/// stored in `meeting.json`. We use it to decide, after the fact, whether the microphone
/// could *acoustically hear* the call:
///
///  - On the **built-in speakers** it can. The remote party's voice comes out of the
///    speakers and bleeds back into the mic, so the mic track alone already contains the
///    whole conversation — and the clean system track only adds a time-delayed duplicate
///    of that same audio (plus any far-end round-trip of your own voice), which is exactly
///    what plays back as echo. So for a loudspeaker recording we build the combined file
///    from the mic alone. (See plans/ECHO-routing.md for the measurements behind this.)
///  - On **headphones / external / Bluetooth / virtual** routes it cannot — the mic only
///    hears you — so both tracks are needed and the combined file stays mic-L / system-R.
///
/// `isLoudspeaker` is deliberately conservative: only the Mac's own internal speakers
/// count. A wrong "loudspeaker" would drop the system track and could lose the remote
/// voice; a wrong "headphones" merely leaves a harmless echo. (And either way the raw
/// system audio is still preserved separately as `system.m4a`.)
public struct OutputRoute: Codable, Equatable, Sendable {
    public var deviceName: String?
    /// A coarse transport label: "BuiltIn", "Bluetooth", "USB", "HDMI", "Virtual", …
    public var transport: String?
    /// The output data source name when the device exposes one ("Speaker", "Headphones").
    public var dataSource: String?
    /// True only when we're confident the output plays from a loudspeaker the mic hears.
    public var isLoudspeaker: Bool

    public init(
        deviceName: String? = nil,
        transport: String? = nil,
        dataSource: String? = nil,
        isLoudspeaker: Bool
    ) {
        self.deviceName = deviceName
        self.transport = transport
        self.dataSource = dataSource
        self.isLoudspeaker = isLoudspeaker
    }

    /// Pure classifier (testable without Core Audio). The mic can only hear the output when
    /// it plays from the Mac's built-in speakers — so require a built-in transport and rule
    /// out the headphone jack, which presents either as a "Headphones" data source or as a
    /// device named "External Headphones" depending on the Mac.
    public static func classifyIsLoudspeaker(
        transport: String?,
        dataSourceName: String?,
        deviceName: String?
    ) -> Bool {
        guard transport == "BuiltIn" else { return false }
        let headphone = "headphone"
        if dataSourceName?.lowercased().contains(headphone) == true { return false }
        if deviceName?.lowercased().contains(headphone) == true { return false }
        return true
    }
}

/// Reads the current default-output route from Core Audio. Best-effort: any failure (no
/// device, a property the device doesn't expose) degrades to `nil` or an "unknown,
/// not-loudspeaker" route rather than throwing — the route is an optimization hint, never
/// something capture should fail on.
public enum OutputRouteProbe {
    public static func current() -> OutputRoute? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard
            let deviceID = try? AudioObjectReader.readAudioObjectID(
                systemObject,
                selector: kAudioHardwarePropertyDefaultOutputDevice
            ),
            deviceID != AudioObjectID(kAudioObjectUnknown)
        else {
            return nil
        }

        let name = try? AudioObjectReader.readCFString(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
        let transport = (try? AudioObjectReader.readUInt32(deviceID, selector: kAudioDevicePropertyTransportType))
            .map(transportLabel)
        let dataSource = readOutputDataSourceName(deviceID: deviceID)

        return OutputRoute(
            deviceName: name,
            transport: transport,
            dataSource: dataSource,
            isLoudspeaker: OutputRoute.classifyIsLoudspeaker(
                transport: transport,
                dataSourceName: dataSource,
                deviceName: name
            )
        )
    }

    private static func transportLabel(_ raw: UInt32) -> String {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        default: return fourCharCode(raw)
        }
    }

    private static func fourCharCode(_ raw: UInt32) -> String {
        let bytes = [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF)
        ]
        let scalars = bytes.filter { $0 >= 0x20 && $0 < 0x7F }
        return scalars.isEmpty ? "0x\(String(raw, radix: 16))" : String(bytes: scalars, encoding: .ascii) ?? "unknown"
    }

    /// Reads the *name* of the active output data source (e.g. "Internal Speakers",
    /// "Headphones"). Core Audio reports the source as a numeric ID, then translates that ID
    /// to a localized name through a second `AudioValueTranslation` property — done here with
    /// nested pointer scopes so the in/out buffers stay valid across the HAL call.
    private static func readOutputDataSourceName(deviceID: AudioObjectID) -> String? {
        var sourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var sourceID: UInt32 = 0
        var sourceSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &sourceAddress, 0, nil, &sourceSize, &sourceID) == noErr else {
            return nil
        }

        var translationAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        return withUnsafeMutablePointer(to: &sourceID) { inputPointer -> String? in
            var nameOut: Unmanaged<CFString>?
            return withUnsafeMutablePointer(to: &nameOut) { outputPointer -> String? in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(inputPointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(outputPointer),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                let status = AudioObjectGetPropertyData(
                    deviceID,
                    &translationAddress,
                    0,
                    nil,
                    &translationSize,
                    &translation
                )
                guard status == noErr, let name = outputPointer.pointee else { return nil }
                return name.takeRetainedValue() as String
            }
        }
    }
}
