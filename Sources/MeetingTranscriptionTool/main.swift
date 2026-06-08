import Foundation
import Meeting2Core

struct Arguments {
    var root: URL = URL(fileURLWithPath: NSString(string: "~/Recordings/Meetings").expandingTildeInPath)
    var envFile: URL? = URL(fileURLWithPath: ".env")
    var model: String?
    var json = false

    init(_ raw: [String]) throws {
        var iterator = raw.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--root", "-r":
                guard let value = iterator.next() else {
                    throw CaptureError.invalidState("Expected path after \(arg)")
                }
                root = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            case "--env":
                guard let value = iterator.next() else {
                    throw CaptureError.invalidState("Expected path after \(arg)")
                }
                envFile = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            case "--no-env":
                envFile = nil
            case "--model":
                guard let value = iterator.next() else {
                    throw CaptureError.invalidState("Expected model after \(arg)")
                }
                model = value
            case "--json":
                json = true
            case "--help", "-h":
                print(Self.help)
                exit(0)
            default:
                throw CaptureError.invalidState("Unknown argument: \(arg)")
            }
        }
    }

    static let help = """
    Usage: MeetingTranscriptionTool [--root folder] [--env path] [--model name] [--json]

    Scans compressed recordings with audio.m4a and no transcript.json, sends the
    combined stereo file to Gemini, then writes transcript.json and transcript.md.
    GOOGLE_API_KEY is read from .env or the environment.
    """
}

struct JSONTranscriptionResult: Encodable {
    let folder: String
    let transcriptPath: String
    let markdownPath: String
    let provider: String
    let model: String
    let textCharacterCount: Int
}

struct JSONFailure: Encodable {
    let folder: String
    let error: String
}

struct JSONTranscriptionOutput: Encodable {
    let results: [JSONTranscriptionResult]
    let failures: [JSONFailure]
}

@main
struct MeetingTranscriptionTool {
    static func main() async {
        do {
            let args = try Arguments(CommandLine.arguments)
            let store = MeetingStore(root: args.root)
            let job = TranscriptionJob()
            let pending = try await store.scan().filter { job.needsWork($0) }

            guard !pending.isEmpty else {
                if args.json {
                    // Same `{results, failures}` shape as the work path, so consumers don't
                    // branch on output shape.
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(JSONTranscriptionOutput(results: [], failures: []))
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    print("No compressed recordings to transcribe under \(args.root.path)")
                }
                return
            }

            var configuration = try GeminiTranscriber.Configuration.fromEnvironment(
                envFiles: args.envFile.map { [$0] } ?? []
            )
            if let model = args.model {
                configuration.model = model
            }
            let transcriber = GeminiTranscriber(configuration: configuration)
            // Per-item isolation: a single failed recording no longer aborts the run; it's
            // reported and we exit non-zero so scripts still notice.
            let run = try await job.runPending(in: store, transcriber: transcriber)

            if args.json {
                let output = JSONTranscriptionOutput(
                    results: run.results.map { result in
                        JSONTranscriptionResult(
                            folder: result.folder.path,
                            transcriptPath: result.transcriptURL.path,
                            markdownPath: result.markdownURL.path,
                            provider: result.provider,
                            model: result.model,
                            textCharacterCount: result.textCharacterCount
                        )
                    },
                    failures: run.failures.map { JSONFailure(folder: $0.folder.path, error: $0.message) }
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(output)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(run.failures.isEmpty ? 0 : 1)
            }

            for result in run.results {
                print(
                    "\(result.folder.path): provider=\(result.provider) model=\(result.model) " +
                    "characters=\(result.textCharacterCount) transcript=\(result.transcriptURL.path)"
                )
            }
            for failure in run.failures {
                fputs("\(failure.folder.path): FAILED \(failure.message) (audio preserved)\n", stderr)
            }
            if !run.failures.isEmpty { exit(1) }
        } catch {
            fputs("\(error)\n", stderr)
            fputs(Arguments.help + "\n", stderr)
            exit(1)
        }
    }
}
