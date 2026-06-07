import Foundation
import Meeting2Core

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
    Usage: MeetingCompressionTool [--root folder] [--json]

    Scans finalized recording folders and merges mic.caf/system.caf into a single
    combined audio.m4a (mic left, system right). The CAFs are deleted only after
    audio.m4a validates.
    """
}

struct JSONCompressionResult: Encodable {
    let folder: String
    let status: String
    let didCompress: Bool
    let audioPath: String
    let metadataPath: String
}

@main
struct MeetingCompressionTool {
    static func main() async {
        do {
            let args = try Arguments(CommandLine.arguments)
            let store = MeetingStore(root: args.root)
            let results = try await CompressionJob().runPending(in: store)

            if args.json {
                let json = results.map { result in
                    JSONCompressionResult(
                        folder: result.folder.path,
                        status: result.status.rawValue,
                        didCompress: result.didCompress,
                        audioPath: result.audioURL.path,
                        metadataPath: result.metadataURL.path
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
                print("No finalized CAF recordings to compress under \(args.root.path)")
                return
            }

            for result in results {
                print(
                    "\(result.folder.path): \(result.status.rawValue) " +
                    "audio=\(result.audioURL.path) metadata=\(result.metadataURL.path)"
                )
            }
        } catch {
            fputs("\(error)\n", stderr)
            fputs(Arguments.help + "\n", stderr)
            exit(1)
        }
    }
}
