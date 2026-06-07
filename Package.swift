// swift-tools-version: 5.10

import PackageDescription

// This is a Swift package even though the shipping product will be a menu-bar app.
// Structuring the capture code as a library plus small command-line executables lets
// the risky Core Audio work be built and exercised from the terminal — fast, and with
// no UI or system-permission dialogs in the way — before any app exists. The library
// (Meeting2Core) is the reusable core; the executables are test tools.
let package = Package(
    name: "Meeting2",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(name: "Meeting2Core", targets: ["Meeting2Core"]),
        .executable(name: "CaptureHarness", targets: ["CaptureHarness"]),
        .executable(name: "Meeting2", targets: ["Meeting2"]),
        .executable(name: "AudioDeviceTool", targets: ["AudioDeviceTool"]),
        .executable(name: "AudioAlignmentTool", targets: ["AudioAlignmentTool"]),
        .executable(name: "MeetingRecoveryTool", targets: ["MeetingRecoveryTool"]),
        .executable(name: "MeetingCompressionTool", targets: ["MeetingCompressionTool"]),
        .executable(name: "MeetingTranscriptionTool", targets: ["MeetingTranscriptionTool"])
    ],
    targets: [
        .target(
            name: "TPCircularBuffer",
            path: "Sources/TPCircularBuffer",
            publicHeadersPath: "include"
        ),
        .target(
            name: "Meeting2Core",
            dependencies: ["TPCircularBuffer"],
            path: "Sources/Meeting2Core",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .executableTarget(
            name: "CaptureHarness",
            dependencies: ["Meeting2Core"],
            path: "Sources/CaptureHarness"
        ),
        .executableTarget(
            name: "Meeting2",
            dependencies: ["Meeting2Core"],
            path: "Sources/Meeting2App",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "AudioDeviceTool",
            path: "Sources/AudioDeviceTool",
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "AudioAlignmentTool",
            path: "Sources/AudioAlignmentTool",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .executableTarget(
            name: "MeetingRecoveryTool",
            dependencies: ["Meeting2Core"],
            path: "Sources/MeetingRecoveryTool"
        ),
        .executableTarget(
            name: "MeetingCompressionTool",
            dependencies: ["Meeting2Core"],
            path: "Sources/MeetingCompressionTool"
        ),
        .executableTarget(
            name: "MeetingTranscriptionTool",
            dependencies: ["Meeting2Core"],
            path: "Sources/MeetingTranscriptionTool"
        ),
        .testTarget(
            name: "Meeting2CoreTests",
            dependencies: ["Meeting2Core"],
            path: "Tests/Meeting2CoreTests"
        )
    ]
)
