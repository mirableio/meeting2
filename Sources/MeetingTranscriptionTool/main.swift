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

@main
struct MeetingTranscriptionTool {
    static func main() async {
        do {
            let args = try Arguments(CommandLine.arguments)
            let store = MeetingStore(root: args.root)
            let job = TranscriptionJob()
            let pending = try await store.scan().filter { job.needsWork($0) }

            guard !pending.isEmpty else {
                if !args.json {
                    print("No compressed recordings to transcribe under \(args.root.path)")
                } else {
                    FileHandle.standardOutput.write(Data("[]\n".utf8))
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
            var results: [MeetingTranscriptionResult] = []

            for snapshot in pending {
                results.append(try await job.perform(folder: snapshot.folder, store: store, transcriber: transcriber))
            }

            if args.json {
                let json = results.map { result in
                    JSONTranscriptionResult(
                        folder: result.folder.path,
                        transcriptPath: result.transcriptURL.path,
                        markdownPath: result.markdownURL.path,
                        provider: result.provider,
                        model: result.model,
                        textCharacterCount: result.textCharacterCount
                    )
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(json)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }

            for result in results {
                print(
                    "\(result.folder.path): provider=\(result.provider) model=\(result.model) " +
                    "characters=\(result.textCharacterCount) transcript=\(result.transcriptURL.path)"
                )
            }
        } catch {
            fputs("\(error)\n", stderr)
            fputs(Arguments.help + "\n", stderr)
            exit(1)
        }
    }
}
