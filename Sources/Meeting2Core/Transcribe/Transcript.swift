import Foundation

/// Provider-neutral transcript storage. Gemini is the first implementation, but the
/// disk file should not expose Gemini response shapes or code-derived speaker splits.
/// The model owns the words; this app stores that text verbatim and keeps only enough
/// metadata to know which provider/model produced it.
public struct Transcript: Codable, Equatable {
    public var schemaVersion: Int
    public var provider: String
    public var model: String
    public var language: String?
    public var text: String
    public var createdAt: Date

    public init(
        schemaVersion: Int = 1,
        provider: String,
        model: String,
        language: String? = nil,
        text: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.model = model
        self.language = language
        self.text = text
        self.createdAt = createdAt
    }
}

public enum TranscriptRenderer {
    public static func markdown(from transcript: Transcript) -> String {
        var lines: [String] = []
        lines.append("# Transcript")
        lines.append("")
        lines.append("Provider: \(transcript.provider)")
        lines.append("Model: \(transcript.model)")
        if let language = transcript.language, !language.isEmpty {
            lines.append("Language: \(language)")
        }
        lines.append("")
        lines.append(transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")

        return lines.joined(separator: "\n")
    }
}
