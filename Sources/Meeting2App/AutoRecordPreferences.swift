import AppKit
import Combine
import Meeting2Core

struct ObservedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    var name: String
    var autoRecord: Bool
    var id: String { bundleID }
}

/// One durable choice per reported bundle ID. Discovery happens before policy filtering, so
/// ignored services remain visible and user overrides always win over the initial defaults.
@MainActor
final class AutoRecordPreferences: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var apps: [ObservedApp]
    private(set) var revision: UInt64 = 0
    var onEnabledChanged: ((Bool) -> Void)?
    var onRulesChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let resolveName: (MicOwner) -> String?
    // Keep presentation lookups out of search redraws, including misses for background services.
    // This cache is deliberately separate from persisted app identities and recording policy.
    private var iconCache: [String: NSImage?] = [:]
    private static let appsKey = "AutoRecordApps"
    private static let disabledDefaults: Set<String> = [
        "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.corespeechd", "com.apple.VoiceOver"
    ]

    init(defaults: UserDefaults = .standard, resolveName: @escaping (MicOwner) -> String? = { owner in
        // HAL and AppKit are separate reads: the process could exit and its PID be reused. A
        // mismatched app's friendly name would encourage the user to disable the wrong identity.
        guard let app = NSRunningApplication(processIdentifier: owner.pid),
              app.bundleIdentifier == owner.bundleID else { return nil }
        return app.localizedName
    }) {
        self.defaults = defaults
        self.resolveName = resolveName
        enabled = defaults.bool(forKey: "AutoRecordEnabled")
        apps = defaults.data(forKey: Self.appsKey)
            .flatMap { try? JSONDecoder().decode([ObservedApp].self, from: $0) } ?? []
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        revision &+= 1
        defaults.set(value, forKey: "AutoRecordEnabled")
        onEnabledChanged?(value)
    }

    func allows(_ bundleID: String) -> Bool {
        guard bundleID != MicOwnerMonitor.meeting2BundleID else { return false }
        return apps.first { $0.bundleID == bundleID }?.autoRecord
            ?? !Self.disabledDefaults.contains(bundleID)
    }

    func eligibleOwners(_ owners: Set<String>) -> Set<String> {
        Set(owners.filter(allows))
    }

    func setAutoRecord(_ value: Bool, for bundleID: String) {
        guard let index = apps.firstIndex(where: { $0.bundleID == bundleID }),
              apps[index].autoRecord != value else { return }
        apps[index].autoRecord = value
        revision &+= 1
        save()
        onRulesChanged?()
    }

    /// Return discoveries from this read so the recording that first sees an app can offer the
    /// one-time menu action. The existing persisted list makes later reads and relaunches known.
    @discardableResult
    func observe(_ owners: [MicOwner]) -> Set<String> {
        var updated = apps
        var discovered: Set<String> = []
        for owner in owners.sorted(by: { $0.pid < $1.pid }) {
            guard owner.pid != getpid(), owner.bundleID != MicOwnerMonitor.meeting2BundleID,
                  !owner.bundleID.isEmpty else { continue }
            let name = resolveName(owner).flatMap { $0.isEmpty ? nil : $0 }
            if let index = updated.firstIndex(where: { $0.bundleID == owner.bundleID }) {
                // A process can exit between HAL and AppKit reads. Keep its last useful name.
                if let name { updated[index].name = name }
            } else {
                discovered.insert(owner.bundleID)
                updated.append(ObservedApp(
                    bundleID: owner.bundleID, name: name ?? owner.bundleID,
                    autoRecord: !Self.disabledDefaults.contains(owner.bundleID)
                ))
            }
        }
        updated.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
        guard updated != apps else { return [] }
        apps = updated
        save()
        return discovered
    }

    func matching(_ search: String) -> [ObservedApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? apps : apps.filter {
            $0.name.localizedStandardContains(query) || $0.bundleID.localizedStandardContains(query)
        }
    }

    func name(for bundleID: String) -> String {
        apps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        // updateValue stores a nil lookup result; assigning nil through the subscript removes it.
        iconCache.updateValue(icon, forKey: bundleID)
        return icon
    }

    func resetIconCache() {
        // Refresh on window open so installations/icon changes become visible without per-row
        // invalidation machinery. Notify once here, never from inside a SwiftUI rendering pass.
        objectWillChange.send()
        iconCache.removeAll()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: Self.appsKey) }
    }
}
