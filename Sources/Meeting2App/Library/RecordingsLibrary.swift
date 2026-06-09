import AppKit
import Combine
import Foundation
import Meeting2Core

/// One recording's display status, driving both the row dot and the filters. Derived from a
/// `MeetingSnapshot` plus the live `currentFolder` overlay (a live recording's files alone read
/// as `.interrupted`, so we can't trust `scan()` for it).
enum LibraryStatus {
    case recording
    case transcribing
    case transcribed
    case notTranscribed
    case failed
    case needsAttention
}

/// A row in the library, derived from a `MeetingSnapshot`. The folder URL is the stable id.
struct LibraryItem: Identifiable {
    let id: URL
    let name: String
    let startedAt: Date
    let durationSeconds: Double?
    let status: LibraryStatus
    let statusLabel: String
    let hasTranscript: Bool
    let transcriptMarkdownURL: URL?
    /// Lower-cased text the search field matches against: the name, the folder name (carries the
    /// timestamp, e.g. `2026-06-07 11-44-19`), and a formatted date/time.
    let searchHaystack: String

    var folder: URL { id }

    /// Destructive actions (delete / re-transcribe) are blocked while the recording is being
    /// written — the live one or one mid-transcription.
    var isBusy: Bool { status == .recording || status == .transcribing }

    init(snapshot: MeetingSnapshot, isLive: Bool) {
        let folder = snapshot.folder
        let metadata = snapshot.metadata
        id = folder
        name = metadata?.displayName ?? folder.lastPathComponent
        startedAt = metadata?.startedAt
            ?? (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? Date.distantPast

        if let started = metadata?.startedAt, let ended = metadata?.endedAt {
            durationSeconds = ended.timeIntervalSince(started)
        } else {
            durationSeconds = metadata?.tracks.mic.durationSeconds ?? metadata?.tracks.system.durationSeconds
        }

        hasTranscript = snapshot.hasTranscript
        transcriptMarkdownURL = snapshot.hasTranscript ? folder.appendingPathComponent("transcript.md") : nil
        let computedStatus = Self.status(snapshot: snapshot, isLive: isLive)
        status = computedStatus
        statusLabel = Self.label(for: computedStatus)

        let started = metadata?.startedAt ?? Date.distantPast
        let dateText = started == .distantPast ? "" : started.formatted(date: .abbreviated, time: .shortened)
        searchHaystack = [name, folder.lastPathComponent, dateText]
            .joined(separator: " ")
            .lowercased()
    }

    private static func status(snapshot: MeetingSnapshot, isLive: Bool) -> LibraryStatus {
        if isLive { return .recording }
        // Only *total* silence is treated as broken. Mic-only recording is a normal, common case —
        // an in-person meeting has no system (call) audio at all — so system silence on its own
        // isn't an error here; flagging it would nag every f2f recording, and after the fact we
        // can't tell "f2f" from "the call didn't capture". When BOTH tracks are silent, though,
        // nothing was captured (and any transcript is hallucinated from noise), so attention wins
        // even over the green "transcribed" state. The genuine "call didn't capture" case is caught
        // by the live warning while recording, where the user knows whether they're on a call.
        let health = snapshot.metadata?.audioHealth
        if health?.micSilent == true, health?.systemSilent == true {
            return .needsAttention
        }
        if snapshot.hasTranscript { return .transcribed }
        switch snapshot.metadata?.jobs.transcription.status {
        case .running: return .transcribing
        case .failed: return .failed
        default: break
        }
        switch snapshot.state {
        case .interrupted, .incomplete: return .needsAttention
        default: break
        }
        return .notTranscribed
    }

    static func label(for status: LibraryStatus) -> String {
        switch status {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing…"
        case .transcribed: return "Transcribed"
        case .notTranscribed: return "Not transcribed"
        case .failed: return "Failed"
        case .needsAttention: return "Needs attention"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case pending = "Pending"
    case errors = "Errors"

    var id: String { rawValue }

    func matches(_ status: LibraryStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .pending:
            // Not done and not broken: still recording, being transcribed, or awaiting one.
            switch status {
            case .recording, .transcribing, .notTranscribed: return true
            case .transcribed, .failed, .needsAttention: return false
            }
        case .errors:
            return status == .failed || status == .needsAttention
        }
    }
}

/// A day's worth of rows, with a `Today` / `Yesterday` / dated header.
struct LibrarySection: Identifiable {
    let id: String
    let title: String
    let items: [LibraryItem]
}

@MainActor
final class RecordingsLibraryViewModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published var searchText = ""
    @Published var filter: LibraryFilter = .all
    /// The row under the cursor — the only "active" row (there is no click/keyboard selection).
    /// Not `@Published`: it backs hover-targeted keyboard actions, not rendering (each row tracks
    /// its own hover via local state).
    var hoveredID: URL?
    /// The row currently being renamed inline (driven by the Rename command / Return key).
    @Published var renamingID: URL?

    var hoveredItem: LibraryItem? {
        hoveredID.flatMap { id in items.first { $0.id == id } }
    }

    /// Set by `AppDelegate` to route re-transcribe back through the menu controller's observed
    /// sweep (so the menu shows progress / badges failures like any other transcription).
    var reTranscribeAction: ((URL) -> Void)?

    private let coordinator: RecordingCoordinator
    private var changeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?

    init(coordinator: RecordingCoordinator) {
        self.coordinator = coordinator
        // Event-driven refresh: recordings created/finished/renamed/deleted/re-transcribed.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .meetingLibraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    // MARK: - Loading

    func reload() async {
        let snapshots = await coordinator.recordings()
        // Compare standardized paths, not URLs: the scanned folder and the session's
        // `currentFolder` can differ in representation (trailing slash, symlink resolution),
        // and a missed match would show the live recording as `.interrupted` → needs-attention.
        let live = coordinator.currentFolder?.standardizedFileURL.path
        items = snapshots
            .map { LibraryItem(snapshot: $0, isLive: $0.folder.standardizedFileURL.path == live) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func scheduleReload() {
        Task { await reload() }
    }

    /// Filter → search → group-by-day. Items are already newest-first.
    var visibleSections: [LibrarySection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = items.filter { item in
            filter.matches(item.status) && (query.isEmpty || item.searchHaystack.contains(query))
        }
        return Self.group(filtered)
    }

    private static func group(_ items: [LibraryItem]) -> [LibrarySection] {
        let calendar = Calendar.current
        var sections: [(key: String, title: String, items: [LibraryItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.startedAt)
            let key = String(Int(day.timeIntervalSince1970))
            if sections.last?.key == key {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append((key, sectionTitle(for: day, calendar: calendar), [item]))
            }
        }
        return sections.map { LibrarySection(id: $0.key, title: $0.title, items: $0.items) }
    }

    private static func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return formatter.string(from: day)
    }

    // MARK: - Operations

    func rename(_ item: LibraryItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        Task {
            try? await coordinator.rename(folder: item.folder, to: trimmed)
            await reload()
        }
    }

    func delete(_ item: LibraryItem) {
        Task {
            do {
                try await coordinator.deleteRecording(folder: item.folder)
                items.removeAll { $0.id == item.id } // optimistic; notification also reloads
            } catch {
                DebugDiagnostics.log("library delete failed error=\(error)")
            }
        }
    }

    func reTranscribe(_ item: LibraryItem) {
        guard !item.isBusy else { return }
        reTranscribeAction?(item.folder)
    }

    func openTranscript(_ item: LibraryItem) {
        guard let url = item.transcriptMarkdownURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openFolder(_ item: LibraryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.folder])
    }

    // MARK: - Auto-refresh

    // Most updates arrive via the `.meetingLibraryDidChange` notification, but a transcription
    // grinding away in the background doesn't post on every step. So while the window is open we
    // also re-scan on a slow timer, keeping a row's status (e.g. "Transcribing…" → "Transcribed")
    // current. Off while the window is closed — no point scanning what nobody's looking at.
    func startAutoRefresh() {
        stopAutoRefresh()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
