import AVFoundation
@testable import Meeting2Core
import XCTest

/// Exercise the byte-ring/converter boundary without audio hardware: a Bluetooth
/// clock must change the number of stored frames, never the voice's speed or pitch.
final class TrackWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Meeting2WriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func test24kHzInputPreservesDurationAndPitchAt48kHz() throws {
        let ring = try CircularAudioBuffer(byteCapacity: 400_000)
        let url = directory.appendingPathComponent("system.caf")
        try autoreleasepool {
            let writer = try TrackWriter(url: url, sourceFormat: format(rate: 24_000), ring: ring)
            enqueueTone(rate: 24_000, ring: ring)
            writer.stop()
        }

        let samples = try readSamples(url)
        XCTAssertEqual(Double(samples.count) / 48_000, 1, accuracy: 0.005)
        XCTAssertEqual(frequency(samples[8_000..<32_000]), 1_000, accuracy: 5)
    }

    func testRateChangeDrainsOldFramesBeforeUsingNewConverter() throws {
        let ring = try CircularAudioBuffer(byteCapacity: 400_000)
        let url = directory.appendingPathComponent("system.caf")
        try autoreleasepool {
            let writer = try TrackWriter(url: url, sourceFormat: format(rate: 48_000), ring: ring)
            enqueueTone(rate: 48_000, ring: ring)
            try writer.reconfigure(sourceFormat: format(rate: 24_000))
            enqueueTone(rate: 24_000, ring: ring)
            writer.stop()
        }

        let samples = try readSamples(url)
        XCTAssertEqual(Double(samples.count) / 48_000, 2, accuracy: 0.005)
        XCTAssertEqual(frequency(samples[8_000..<32_000]), 1_000, accuracy: 5)
        XCTAssertEqual(frequency(samples[56_000..<80_000]), 1_000, accuracy: 5)
    }

    private func format(rate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    }

    private func enqueueTone(rate: Int, ring: CircularAudioBuffer) {
        let samples = (0..<rate).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / Double(rate))) }
        samples.withUnsafeBytes { bytes in
            XCTAssertTrue(ring.produce(bytes.baseAddress!, byteCount: bytes.count))
        }
    }

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var samples: [Float] = []
        // AVAudioFile may return less than the requested capacity before EOF.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    private func frequency(_ samples: ArraySlice<Float>) -> Double {
        var crossings = 0
        for index in samples.startIndex + 1..<samples.endIndex {
            if samples[index - 1] <= 0, samples[index] > 0 { crossings += 1 }
        }
        return Double(crossings) * 48_000 / Double(samples.count)
    }
}
