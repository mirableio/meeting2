import Foundation

public struct TranscriptionHints: Sendable {
    public let meetingID: String
    public let displayName: String

    public init(meetingID: String, displayName: String) {
        self.meetingID = meetingID
        self.displayName = displayName
    }
}

public protocol Transcriber {
    var id: String { get }
    var model: String { get }

    func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript
}

/// A problem that prevents building a transcriber at all (vs. a failure transcribing one
/// recording). It's matched by *type* — not by a message substring — so the UI can treat
/// "transcription isn't set up" as opt-in (no nag) without depending on the exact wording of
/// any provider's error.
public enum TranscriptionConfigurationError: Error, Equatable, CustomStringConvertible {
    case missingAPIKey

    public var description: String {
        switch self {
        case .missingAPIKey:
            return "No transcription API key configured — set GOOGLE_API_KEY in .env or the environment"
        }
    }
}
