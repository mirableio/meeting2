@testable import Meeting2
import AppKit
import Meeting2Core
import SwiftUI
import XCTest

/// Native window integration uses isolated preferences and never creates a recorder. Optional
/// snapshots make it possible to inspect minimum-size wrapping and both appearances locally.
@MainActor
final class SettingsWindowTests: XCTestCase {
    func testClosingOneWindowKeepsOtherWindowInNormalAppMode() async {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let delegate = AppDelegate()
        let first = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer {
            first.close()
            second.close()
            app.setActivationPolicy(originalPolicy)
        }
        delegate.userWindowWillOpen(first)
        delegate.userWindowWillOpen(second)
        second.miniaturize(nil)
        delegate.userWindowWillClose(first)
        XCTAssertEqual(app.activationPolicy(), .regular)
        delegate.userWindowWillClose(second)
        XCTAssertEqual(app.activationPolicy(), .accessory)
    }

    func testSettingsLayoutAtMinimumAndDefaultSizes() async throws {
        _ = NSApplication.shared
        let suite = "Meeting2Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = [
            "us.zoom.xos": "Zoom Workplace",
            "com.apple.Safari": "Safari",
            "com.apple.CoreSpeech": "CoreSpeech",
            "com.example.dictation": "Dictation with a deliberately long application name"
        ]
        let preferences = AutoRecordPreferences(defaults: defaults, resolveName: { names[$0.bundleID] })
        preferences.observe(names.keys.enumerated().map { MicOwner(bundleID: $0.element, pid: pid_t(-10 - $0.offset)) })
        preferences.setAutoRecord(false, for: "com.example.dictation")
        let hosting = NSHostingController(rootView: AutoRecordSettingsView(preferences: preferences))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Meeting2 Settings Preview"
        defer { window.close() }
        let snapshotDirectory = ProcessInfo.processInfo.environment["MEETING2_UI_SNAPSHOT_DIR"]
        for (label, size, appearance) in [
            ("default", NSSize(width: 600, height: 500), NSAppearance.Name.aqua),
            ("minimum", NSSize(width: 460, height: 320), NSAppearance.Name.aqua),
            ("dark", NSSize(width: 600, height: 500), NSAppearance.Name.darkAqua)
        ] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            // Layout is synchronous and can be checked offscreen. Only the explicit visual-QA
            // run needs a visible window and time for the native controls to finish rendering.
            if snapshotDirectory != nil {
                window.orderFront(nil)
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.view.bounds.size, size)
            XCTAssertFalse(hosting.view.hasAmbiguousLayout)
            if let directory = snapshotDirectory {
                let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let folder = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent("settings-\(label).png"))
            } else {
                XCTAssertFalse(window.isVisible)
            }
        }
    }
}
