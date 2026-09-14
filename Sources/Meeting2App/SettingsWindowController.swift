import AppKit
import SwiftUI
import Meeting2Core

/// A single reusable window. Refreshing discovery here is read-only and works with the global
/// switch off; it never invokes the automatic-recording controller's start decision.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let preferences: AutoRecordPreferences
    private let monitor: MicOwnerMonitor
    private var window: NSWindow?
    var onOpen: ((NSWindow) -> Void)?
    var onClose: ((NSWindow) -> Void)?

    init(preferences: AutoRecordPreferences, monitor: MicOwnerMonitor) {
        self.preferences = preferences
        self.monitor = monitor
    }

    func show() {
        preferences.resetIconCache()
        let window = existingOrNewWindow()
        onOpen?(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task {
            if let owners = await monitor.refreshExternalOwners() { preferences.observe(owners) }
        }
    }

    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }
        let hosting = NSHostingController(rootView: AutoRecordSettingsView(preferences: preferences))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 500))
        window.minSize = NSSize(width: 460, height: 320)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { onClose?(window) }
    }
}

/// Keep the list keyed by reported bundle ID. Labels and icons are best-effort presentation and
/// cannot merge helpers, change a saved preference, or make an unknown app disappear from search.
struct AutoRecordSettingsView: View {
    @ObservedObject var preferences: AutoRecordPreferences
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Detect meetings automatically")
                Spacer()
                Toggle("Detect meetings automatically", isOn: Binding(
                    get: { preferences.enabled }, set: { preferences.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Detect meetings automatically")
            }
            .padding(16)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search apps")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(12)
            Divider()
            HStack {
                Text("Applications")
                Spacer()
                Text("Auto-record")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            let apps = preferences.matching(search)
            if apps.isEmpty {
                ContentUnavailableView(
                    preferences.apps.isEmpty ? "No apps detected" : "No matching apps",
                    systemImage: preferences.apps.isEmpty ? "mic" : "magnifyingglass"
                )
            } else {
                List(apps) { app in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = preferences.icon(for: app.bundleID) {
                                Image(nsImage: icon).resizable()
                            } else {
                                Image(systemName: "waveform").resizable().foregroundStyle(.secondary)
                            }
                        }
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).lineLimit(2)
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .help(app.bundleID)
                        Spacer(minLength: 12)
                        Toggle("Auto-record for \(app.name)", isOn: Binding(
                            get: { preferences.allows(app.bundleID) },
                            set: { preferences.setAutoRecord($0, for: app.bundleID) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Auto-record for \(app.name)")
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
