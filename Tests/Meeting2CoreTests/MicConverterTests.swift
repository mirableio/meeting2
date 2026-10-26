import AVFoundation
@testable import Meeting2Core
import XCTest

/// Exercise real AVAudioConverter mappings without opening a microphone. A valid
/// surround/discrete layout can silently discard channel zero when reduced to mono.
final class MicConverterTests: XCTestCase {
    func testThreeChannelMicrophonePreservesFirstInputAcrossLayoutsAndRates() throws {
        for tag in [kAudioChannelLayoutTag_ITU_3_0, kAudioChannelLayoutTag_DiscreteInOrder | 3] {
            for rate in [24_000.0, 48_000.0] {
                let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
                let converter = try XCTUnwrap(MicCapture.makeConverter(from: format))
                XCTAssertEqual(converter.channelMap, [0])
                let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
                input.frameLength = 4_096
                for channel in 0..<3 {
                    for frame in 0..<4_096 {
                        input.floatChannelData![channel][frame] = channel == 0 ? 0.25 * sin(Float(frame) * 0.1) : 0
                    }
                }
                let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AudioFormat.pcmFormat, frameCapacity: 9_000))
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                XCTAssertNil(error)
                XCTAssertNotEqual(status, .error)
                XCTAssertEqual(Double(output.frameLength), 4_096 * AudioFormat.sampleRate / rate, accuracy: 256)
                let samples = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
                let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
                XCTAssertGreaterThan(rms, 0.1, "layout=\(tag), rate=\(rate) discarded the microphone")
            }
        }
    }

    func testMatchingMonoInputNeedsNoConverter() throws {
        XCTAssertNil(try MicCapture.makeConverter(from: AudioFormat.pcmFormat))
    }
}
