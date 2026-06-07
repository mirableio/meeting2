import Foundation
import OSLog

// Diagnostics for intermittent capture failures. This is intentionally separate from
// product metadata: `meeting.json` should stay a durable user-facing contract, while
// `events.log` is a temporary engineering timeline for "why did this capture go
// silent?" questions. Release builds stay quiet until a future app setting explicitly
// opts in; debug builds write breadcrumbs because that is when we are actively testing
// permissions, route changes, and Core Audio behavior on real hardware.
public enum DebugDiagnostics {
    private static let logger = Logger(subsystem: "com.mirable.Meeting2", category: "diagnostics")
    private static let queue = DispatchQueue(label: "meetingrec.debug-diagnostics")

    public static var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        // Later this can be backed by an app setting. Keep release builds quiet
        // until the user explicitly asks for diagnostic capture.
        return false
        #endif
    }

    public static func log(recordingFolder: URL? = nil, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }

        let text = message()
        logger.info("\(text, privacy: .public)")

        guard let recordingFolder else { return }

        // File IO is serialized off the capture path. Callers may be on UI, store, or
        // writer queues; none of them should block behind disk flushes for debug-only
        // evidence. Never call this from a Core Audio IOProc.
        queue.async {
            do {
                try FileManager.default.createDirectory(at: recordingFolder, withIntermediateDirectories: true)
                let line = "\(Self.timestamp()) \(text)\n"
                let url = recordingFolder.appendingPathComponent("events.log")
                let data = Data(line.utf8)

                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url, options: [.withoutOverwriting])
                }
            } catch {
                logger.error("events.log write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    public static func log(recordingFile: URL, _ message: @autoclosure () -> String) {
        log(recordingFolder: recordingFile.deletingLastPathComponent(), message())
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
