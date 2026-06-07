import Foundation

// Shared coders for `meeting.json`. The formatting choices are deliberate, because this
// file is a durable, user-inspectable contract — not an opaque blob:
//  - `prettyPrinted` + `sortedKeys`: the file is meant to be opened in Finder and to diff
//    cleanly in git/iCloud; stable key order means a one-field change is a one-line diff.
//  - `withoutEscapingSlashes`: keeps paths/URLs readable.
//  - `iso8601` dates: human-readable and unambiguous across machines and time zones.
enum MeetingJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// Durable JSON writes for metadata that must survive a crash. Every `meeting.json` write
// goes through here so the invariant holds everywhere: a reader at any instant sees either
// the complete old file or the complete new one — never a torn half-write.
enum AtomicJSON {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let data = try MeetingJSON.encoder.encode(value)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

        try data.write(to: tempURL, options: [.withoutOverwriting])
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.synchronize()
        try handle.close()

        // `Data.write(.atomic)` is convenient, but it does not make the fsync
        // decision visible. For meeting metadata we want the boring, auditable
        // sequence: write temp in the same directory, flush it, then atomically
        // replace the real file. A crash leaves either version, never JSON rubble.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(
                url,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try MeetingJSON.decoder.decode(type, from: data)
    }
}
