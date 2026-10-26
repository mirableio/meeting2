import Foundation

public struct GeminiTranscriber: Transcriber {
    public struct Configuration: Sendable {
        public static let defaultModel = "gemini-3-flash-preview"
        public static let defaultPrompt = """
        First determine whether the audio contains clearly intelligible human speech. If the audio is silent, or contains only non-speech sounds such as keyboard typing, room noise, breathing, output exactly:
        [silence]

        If there is clear speech, transcribe this dialog (in the language they speak), very thoroughly. format without timestamps, by speaker:
        speaker 1: text
        speaker 2: text
        """

        public var apiKey: String
        public var model: String
        public var prompt: String

        public init(
            apiKey: String,
            model: String = Self.defaultModel,
            prompt: String = Self.defaultPrompt
        ) {
            self.apiKey = apiKey
            self.model = model
            self.prompt = prompt
        }

        public static func fromEnvironment(envFiles: [URL] = []) throws -> Configuration {
            var values: [String: String] = [:]
            for envFile in envFiles {
                guard FileManager.default.fileExists(atPath: envFile.path) else { continue }
                values.merge(try parseEnvFile(envFile)) { _, new in new }
            }
            values.merge(ProcessInfo.processInfo.environment) { _, environment in environment }

            guard let apiKey = values["GOOGLE_API_KEY"],
                  !apiKey.isEmpty else {
                throw TranscriptionConfigurationError.missingAPIKey
            }

            return Configuration(
                apiKey: apiKey,
                model: values["GEMINI_MODEL"] ?? defaultModel,
                prompt: values["GEMINI_PROMPT"] ?? defaultPrompt
            )
        }

        private static func parseEnvFile(_ url: URL) throws -> [String: String] {
            let text = try String(contentsOf: url, encoding: .utf8)
            var values: [String: String] = [:]

            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#"),
                      let separator = line.firstIndex(of: "=") else {
                    continue
                }

                let key = String(line[..<separator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                    (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                values[key] = value
            }

            return values
        }
    }

    private struct GeminiFile: Decodable {
        let name: String
        let uri: String
        let mimeType: String?
    }

    private struct UploadResponse: Decodable {
        let file: GeminiFile?
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }

                let parts: [Part]?
            }

            let content: Content?
            let finishReason: String?
        }

        struct APIError: Decodable {
            let code: Int?
            let message: String
            let status: String?
        }

        let candidates: [Candidate]?
        let error: APIError?
        struct Usage: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
        }
        let usageMetadata: Usage?
    }

    private struct GenerateRequest: Encodable {
        struct Content: Encodable {
            let parts: [Part]
        }

        struct Part: Encodable {
            struct FileData: Encodable {
                let mimeType: String
                let fileURI: String

                enum CodingKeys: String, CodingKey {
                    case mimeType = "mime_type"
                    case fileURI = "file_uri"
                }
            }

            let text: String?
            let fileData: FileData?

            enum CodingKeys: String, CodingKey {
                case text
                case fileData = "file_data"
            }
        }

        struct GenerationConfig: Encodable {
            struct ThinkingConfig: Encodable {
                let thinkingBudget: Int
            }
            let temperature: Double
            let maxOutputTokens: Int?
            let thinkingConfig: ThinkingConfig?
        }

        let contents: [Content]
        let generationConfig: GenerationConfig
    }

    public let id = "gemini"
    public let model: String

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration
        self.model = configuration.model
        self.session = session ?? Self.longRunningSession
    }

    /// Transcribing a long meeting is a single, non-streaming `generateContent` call: Gemini
    /// holds the connection and sends nothing until the whole transcript is ready. For a long
    /// recording that's well past URLSession's default 60s request timeout — we hit exactly
    /// that (NSURLErrorDomain -1001) on a 76-minute meeting — so give it generous timeouts.
    /// (The durable fix is streaming, where the idle timeout only spans gaps between tokens.)
    ///
    /// One shared session, not one per transcriber: a transcriber is built per batch, and a
    /// fresh un-invalidated URLSession each time would slowly leak. The config is fixed, so
    /// reuse is safe.
    private static let longRunningSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600     // 10 min with no bytes before giving up
        config.timeoutIntervalForResource = 1_800  // 30 min hard ceiling for the whole exchange
        return URLSession(configuration: config)
    }()

    public func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript {
        let uploadedFile = try await upload(audioFile: audioFile, displayName: "\(hints.meetingID)-transcript.m4a")
        do {
            let rawText = try await generateTranscript(file: uploadedFile, audioFile: audioFile)
            // Await cleanup before returning: the development CLI can exit as soon as
            // this method finishes, which would abandon an unstructured deletion task.
            try? await deleteRemoteFile(named: uploadedFile.name)
            return Transcript(provider: id, model: model, text: rawText)
        } catch {
            try? await deleteRemoteFile(named: uploadedFile.name)
            throw error
        }
    }

    private func upload(audioFile: URL, displayName: String) async throws -> GeminiFile {
        let fileSize = try audioFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0 else {
            throw CaptureError.invalidState("Transcript audio file is empty: \(audioFile.path)")
        }
        DebugDiagnostics.log(recordingFile: audioFile, "Gemini upload started bytes=\(fileSize)")

        let uploadURL = try await startUpload(
            displayName: displayName,
            byteCount: fileSize,
            mimeType: "audio/m4a"
        )
        let responseData = try await uploadBytes(audioFile: audioFile, uploadURL: uploadURL, byteCount: fileSize)
        let response = try MeetingJSON.decoder.decode(UploadResponse.self, from: responseData)
        guard let file = response.file, !file.uri.isEmpty else {
            throw CaptureError.invalidState("Gemini file upload did not return a usable file URI")
        }
        DebugDiagnostics.log(recordingFile: audioFile, "Gemini upload finished")
        return file
    }

    private func startUpload(displayName: String, byteCount: Int, mimeType: String) async throws -> URL {
        let url = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(byteCount), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["file": ["display_name": displayName]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        let http = try Self.checkedHTTPResponse(response, operation: "Gemini upload start")
        guard let uploadURLString = http.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLString) else {
            throw CaptureError.invalidState("Gemini upload start did not return x-goog-upload-url")
        }
        return uploadURL
    }

    private func uploadBytes(audioFile: URL, uploadURL: URL, byteCount: Int) async throws -> Data {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
        request.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: request, fromFile: audioFile)
        _ = try Self.checkedHTTPResponse(response, operation: "Gemini upload finalize")
        return data
    }

    private func generateTranscript(file: GeminiFile, audioFile: URL) async throws -> String {
        let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = GenerateRequest(
            contents: [
                .init(parts: [
                    .init(text: configuration.prompt, fileData: nil),
                    .init(
                        text: nil,
                        fileData: .init(mimeType: file.mimeType ?? "audio/m4a", fileURI: file.uri)
                    )
                ])
            ],
            // Reserve the documented Gemini 3 Flash output budget for long meetings;
            // still reject MAX_TOKENS below rather than save a plausible fragment as done.
            generationConfig: .init(
                temperature: 1.0,
                maxOutputTokens: model == Configuration.defaultModel ? 65_536 : nil,
                // High and medium both exhausted the shared output budget on a real
                // 95-minute call (62,910 / 49,281 thinking tokens). Request a numeric
                // budget instead of a relative level, leaving room for the transcript.
                // The provider can overshoot this target; STOP validation still matters.
                thinkingConfig: model == Configuration.defaultModel ? .init(thinkingBudget: 8_192) : nil
            )
        )
        request.httpBody = try MeetingJSON.encoder.encode(body)

        DebugDiagnostics.log(
            recordingFile: audioFile,
            "Gemini generation started model=\(model) " +
            "maxOutputTokens=\(body.generationConfig.maxOutputTokens ?? -1) " +
            "thinkingBudget=\(body.generationConfig.thinkingConfig?.thinkingBudget ?? -1)"
        )
        let (data, response) = try await session.data(for: request)
        _ = try Self.checkedHTTPResponse(response, operation: "Gemini generateContent", body: data)
        return try Self.transcriptText(from: data, recordingFile: audioFile)
    }

    // Keep provider completion validation at the HTTP boundary. A nonempty response
    // can still be truncated or blocked; the job must remain failed/retryable then.
    static func transcriptText(from data: Data, recordingFile: URL? = nil) throws -> String {
        let decoded = try MeetingJSON.decoder.decode(GenerateResponse.self, from: data)
        if let error = decoded.error {
            throw CaptureError.invalidState(
                "Gemini error \(error.code.map(String.init) ?? "unknown") " +
                "\(error.status ?? ""): \(error.message)"
            )
        }

        let candidate = decoded.candidates?.first
        let reason = candidate?.finishReason ?? "missing"
        let usage = decoded.usageMetadata
        let completion = "finishReason=\(reason) inputTokens=\(usage?.promptTokenCount ?? -1) " +
            "outputTokens=\(usage?.candidatesTokenCount ?? -1) thinkingTokens=\(usage?.thoughtsTokenCount ?? -1)"
        DebugDiagnostics.log(recordingFolder: recordingFile?.deletingLastPathComponent(), "Gemini completion \(completion)")
        guard reason == "STOP" else {
            throw CaptureError.invalidState("Gemini did not complete transcription: \(completion)")
        }

        // Candidates are alternatives, not consecutive transcript sections. Thought
        // summaries are diagnostics, not the speaker text the user asked to save.
        let text = (candidate?.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.invalidState("Gemini returned an empty transcript")
        }
        return text
    }

    private func deleteRemoteFile(named name: String) async throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")

        let (_, response) = try await session.data(for: request)
        _ = try Self.checkedHTTPResponse(response, operation: "Gemini file delete")
    }

    private static func checkedHTTPResponse(
        _ response: URLResponse,
        operation: String,
        body: Data = Data()
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CaptureError.invalidState("\(operation) did not return an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            throw CaptureError.invalidState("\(operation) HTTP \(http.statusCode) \(text)")
        }
        return http
    }
}
