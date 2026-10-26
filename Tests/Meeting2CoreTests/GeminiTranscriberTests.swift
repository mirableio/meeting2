import Foundation
@testable import Meeting2Core
import XCTest

/// Provider fixtures pin completion semantics without network calls or model text
/// heuristics. Truncated text must never become a successful durable transcript.
final class GeminiTranscriberTests: XCTestCase {
    func testCompletedTranscriptPreservesTextAndExcludesThoughtsAndAlternativeCandidates() throws {
        let data = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"internal summary","thought":true},{"text":"speaker 1: Hello."},{"text":"speaker 2: Hi."}]}},{"finishReason":"STOP","content":{"parts":[{"text":"alternative"}]}}]}"#.utf8)
        XCTAssertEqual(try GeminiTranscriber.transcriptText(from: data), "speaker 1: Hello.\nspeaker 2: Hi.")
    }

    func testIncompleteOrMissingCompletionIsRejectedEvenWithText() throws {
        for reason in ["MAX_TOKENS", "SAFETY", "RECITATION", "OTHER", "CONTINUATION", ""] {
            let candidate: [String: Any] = [
                "finishReason": reason,
                "content": ["parts": [["text": "speaker 1: A plausible fragment."]]]
            ]
            let data = try JSONSerialization.data(withJSONObject: [
                "candidates": [candidate],
                "usageMetadata": ["candidatesTokenCount": 65_536, "thoughtsTokenCount": 123]
            ])
            XCTAssertThrowsError(try GeminiTranscriber.transcriptText(from: data)) { error in
                XCTAssertTrue(String(describing: error).contains("did not complete transcription"))
                XCTAssertTrue(String(describing: error).contains("outputTokens=65536"))
            }
        }
        XCTAssertThrowsError(try GeminiTranscriber.transcriptText(from: Data(#"{"candidates":[{"content":{"parts":[{"text":"fragment"}]}}]}"#.utf8)))
        XCTAssertThrowsError(try GeminiTranscriber.transcriptText(from: Data(#"{"candidates":[]}"#.utf8)))
    }

    func testEmptyStoppedResponseAndProviderErrorsAreRejected() {
        XCTAssertThrowsError(try GeminiTranscriber.transcriptText(from: Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"  "}]}}]}"#.utf8)))
        XCTAssertThrowsError(try GeminiTranscriber.transcriptText(from: Data(#"{"error":{"code":429,"message":"quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#.utf8)))
    }

    func testTruncatedResponseLeavesJobFailedWithoutTranscriptFiles() async throws {
        // Exercise the normal job/store boundary too: rejecting partial model text
        // must leave no success marker that would prevent the next retry.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appendingPathComponent("audio.m4a"))
        try AtomicJSON.write(
            MeetingMetadata(id: "meeting", displayName: "Test", startedAt: Date(), endedAt: Date()),
            to: MeetingStore.metadataURL(in: folder)
        )
        let store = MeetingStore(root: root)
        do {
            _ = try await TranscriptionJob().perform(folder: folder, store: store, transcriber: TruncatedResponse())
            XCTFail("Partial transcript was accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("MAX_TOKENS"))
        }
        let snapshot = try await store.snapshot(folder: folder)
        XCTAssertEqual(snapshot.metadata?.jobs.transcription.status, .failed)
        XCTAssertTrue(TranscriptionJob().needsWork(snapshot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))
    }

    func testRequestPreservesPromptAndTemperatureAndBudgetsDefaultModel() async throws {
        // Pin the actual HTTP payload, including the upload/generate/delete flow,
        // without spending API quota or relying on a live model's response quality.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio.m4a")
        try Data("test audio".utf8).write(to: audio)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for model in [GeminiTranscriber.Configuration.defaultModel, "custom-model"] {
            let transcriber = GeminiTranscriber(configuration: .init(apiKey: "test", model: model), session: session)
            let transcript = try await transcriber.transcribe(
                audioFile: audio, hints: TranscriptionHints(meetingID: "test", displayName: "Test")
            )
            XCTAssertEqual(transcript.text, "speaker 1: Complete.")
        }
    }
}

private struct TruncatedResponse: Transcriber {
    let id = "gemini"
    let model = "gemini-3-flash-preview"

    func transcribe(audioFile: URL, hints: TranscriptionHints) async throws -> Transcript {
        let data = Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"speaker 1: Fragment."}]}}]}"#.utf8)
        return Transcript(provider: id, model: model, text: try GeminiTranscriber.transcriptText(from: data))
    }
}

private final class GeminiHTTPStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            var headers: [String: String] = [:]
            let body: Data
            if request.httpMethod == "DELETE" {
                body = Data("{}".utf8)
            } else if url.path == "/upload/v1beta/files" {
                headers["x-goog-upload-url"] = "https://generativelanguage.googleapis.com/test-upload"
                body = Data("{}".utf8)
            } else if url.path == "/test-upload" {
                body = Data(#"{"file":{"name":"files/test","uri":"https://generativelanguage.googleapis.com/v1beta/files/test","mimeType":"audio/m4a"}}"#.utf8)
            } else if url.path.hasSuffix(":generateContent") {
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4_096)
                    while true {
                        let count = stream.read(&bytes, maxLength: bytes.count)
                        guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                        if count == 0 { break }
                        data.append(contentsOf: bytes.prefix(count))
                    }
                }
                let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let config = try XCTUnwrap(payload["generationConfig"] as? [String: Any])
                XCTAssertEqual(config["temperature"] as? Double, 1)
                if url.path.contains(GeminiTranscriber.Configuration.defaultModel) {
                    XCTAssertEqual(config["maxOutputTokens"] as? Int, 65_536)
                    let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
                    XCTAssertEqual(thinking["thinkingBudget"] as? Int, 8_192)
                    XCTAssertNil(thinking["thinkingLevel"])
                } else {
                    XCTAssertNil(config["maxOutputTokens"])
                    XCTAssertNil(config["thinkingConfig"])
                }
                let contents = try XCTUnwrap(payload["contents"] as? [[String: Any]])
                let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
                XCTAssertEqual(parts.first?["text"] as? String, GeminiTranscriber.Configuration.defaultPrompt)
                body = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"speaker 1: Complete."}]}}]}"#.utf8)
            } else {
                throw URLError(.unsupportedURL)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
