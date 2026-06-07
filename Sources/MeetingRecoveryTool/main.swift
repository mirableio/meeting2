import Foundation
import Meeting2Core

// Dev executable that stands in for "app launched, now reconcile disk state."
// Keeping recovery invokable from Make gives M2 a hard gate before there is a UI:
// kill the recorder, run this tool, and inspect the resulting meeting.json.
struct Arguments {
    var root: URL = URL(fileURLWithPath: NSString(string: "~/Recordings/Meetings").expandingTildeInPath)
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
    Usage: MeetingRecoveryTool [--root folder] [--json]

    Scans recording folders as the app would on launch, validates interrupted
    mic.caf/system.caf pairs, and writes meeting.json atomically.
    """
}

struct JSONRecoveryResult: Encodable {
    let folder: String
    let previousState: String
    let recoveredState: String
    let recovered: Bool
    let metadataPath: String
    let message: String
}

@main
struct MeetingRecoveryTool {
    static func main() async {
        do {
            let args = try Arguments(CommandLine.arguments)
            let store = MeetingStore(root: args.root)
            let results = try await store.recoverInterruptedRecordings()

            if args.json {
                let json = results.map { result in
                    JSONRecoveryResult(
                        folder: result.folder.path,
                        previousState: result.previousState.rawValue,
                        recoveredState: result.recoveredState.rawValue,
                        recovered: result.didRecover,
                        metadataPath: result.metadataURL.path,
                        message: result.message
                    )
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(json)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }

            if results.isEmpty {
                print("No interrupted recordings to recover under \(args.root.path)")
                return
            }

            for result in results {
                if result.didRecover {
                    print(
                        "\(result.folder.path): \(result.previousState.rawValue) -> " +
                        "\(result.recoveredState.rawValue) (\(result.metadataURL.path))"
                    )
                } else {
                    print("\(result.folder.path): \(result.message)")
                }
            }
        } catch {
            fputs("\(error)\n", stderr)
            fputs(Arguments.help + "\n", stderr)
            exit(1)
        }
    }
}
