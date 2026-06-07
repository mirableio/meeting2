import AVFoundation
import Foundation

// Test-only utility for checking that the two recorded files can be lined up in time.
// The product never needs sample-perfect sync (we align words, not waveforms), but we
// do need to prove the alignment is good enough: this tool plays a known click pattern,
// then measures the time offset between the two recordings by cross-correlation. It
// lives outside the recorder on purpose, so that correlation math never creeps into the
// recording path, which must stay nothing but "samples -> disk".
enum AlignmentError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case unsupportedFormat(String)
    case noCorrelation
    case failedThreshold(lagMS: Int, thresholdMS: Int, correlation: Double)

    var description: String {
        switch self {
        case let .invalidArgument(message):
            return message
        case let .unsupportedFormat(message):
            return "Unsupported format: \(message)"
        case .noCorrelation:
            return "Could not find a usable correlation peak"
        case let .failedThreshold(lagMS, thresholdMS, correlation):
            return "Alignment lag \(lagMS)ms exceeds threshold \(thresholdMS)ms (correlation \(String(format: "%.3f", correlation)))"
        }
    }
}

struct AudioSamples {
    let sampleRate: Double
    let samples: [Float]
}

let help = """
Usage:
  AudioAlignmentTool generate-clicks <output.caf> [duration-seconds]
  AudioAlignmentTool analyze <mic.caf> <system.caf> [threshold-ms] [max-lag-ms] [start-delta-ms]

The analyzer estimates lag from 1ms RMS envelopes. A positive lag means the mic
track trails the system track.
"""

func readMonoFloat(_ url: URL) throws -> AudioSamples {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat

    guard format.commonFormat == .pcmFormatFloat32 else {
        throw AlignmentError.unsupportedFormat("\(url.lastPathComponent) is not Float32 PCM")
    }

    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw AlignmentError.unsupportedFormat("Could not allocate buffer for \(url.lastPathComponent)")
    }

    try file.read(into: buffer)
    let frames = Int(buffer.frameLength)
    let channels = Int(format.channelCount)
    guard frames > 0, channels > 0, let channelData = buffer.floatChannelData else {
        throw AlignmentError.unsupportedFormat("\(url.lastPathComponent) has no readable audio")
    }

    var samples = Array(repeating: Float(0), count: frames)
    for channel in 0..<channels {
        let data = channelData[channel]
        for frame in 0..<frames {
            samples[frame] += data[frame] / Float(channels)
        }
    }

    return AudioSamples(sampleRate: format.sampleRate, samples: samples)
}

func rmsEnvelope(samples: [Float], sampleRate: Double, binMS: Int = 1) -> [Double] {
    let binSize = max(1, Int(sampleRate * Double(binMS) / 1000.0))
    let binCount = samples.count / binSize
    guard binCount > 0 else { return [] }

    var envelope = Array(repeating: Double(0), count: binCount)
    for bin in 0..<binCount {
        let start = bin * binSize
        let end = start + binSize
        var sum = Double(0)
        for index in start..<end {
            let sample = Double(samples[index])
            sum += sample * sample
        }
        envelope[bin] = sqrt(sum / Double(binSize))
    }

    // Remove the slow baseline so correlation locks onto click transients instead
    // of room noise or low-level device hum.
    let mean = envelope.reduce(0, +) / Double(envelope.count)
    return envelope.map { max(0, $0 - mean) }
}

func normalizedCorrelation(_ a: [Double], _ b: [Double], lag: Int) -> Double? {
    let startA = max(0, -lag)
    let startB = max(0, lag)
    let count = min(a.count - startA, b.count - startB)
    guard count > 50 else { return nil }

    var dot = Double(0)
    var energyA = Double(0)
    var energyB = Double(0)

    for offset in 0..<count {
        let av = a[startA + offset]
        let bv = b[startB + offset]
        dot += av * bv
        energyA += av * av
        energyB += bv * bv
    }

    guard energyA > 0, energyB > 0 else { return nil }
    return dot / sqrt(energyA * energyB)
}

func analyze(micURL: URL, systemURL: URL, thresholdMS: Int, maxLagMS: Int, startDeltaMS: Int) throws {
    let mic = try readMonoFloat(micURL)
    let system = try readMonoFloat(systemURL)

    guard abs(mic.sampleRate - system.sampleRate) < 0.5 else {
        throw AlignmentError.unsupportedFormat("sample rates differ: mic=\(mic.sampleRate), system=\(system.sampleRate)")
    }

    let micEnvelope = rmsEnvelope(samples: mic.samples, sampleRate: mic.sampleRate)
    let systemEnvelope = rmsEnvelope(samples: system.samples, sampleRate: system.sampleRate)

    var bestLag = 0
    var bestCorrelation = -Double.infinity

    for lag in (-maxLagMS)...maxLagMS {
        guard let correlation = normalizedCorrelation(systemEnvelope, micEnvelope, lag: lag) else {
            continue
        }
        if correlation > bestCorrelation {
            bestCorrelation = correlation
            bestLag = lag
        }
    }

    guard bestCorrelation.isFinite, bestCorrelation > 0.05 else {
        throw AlignmentError.noCorrelation
    }

    // The raw correlation is measured in file time, but the two files begin at
    // different host times because the system tap starts before the mic engine.
    // Correcting by host delta is the contract we will later persist in meeting.json.
    let correctedLag = bestLag + startDeltaMS
    print("rawLagMS=\(bestLag) startDeltaMS=\(startDeltaMS) correctedLagMS=\(correctedLag) correlation=\(String(format: "%.3f", bestCorrelation)) thresholdMS=\(thresholdMS)")

    guard abs(correctedLag) <= thresholdMS else {
        throw AlignmentError.failedThreshold(lagMS: correctedLag, thresholdMS: thresholdMS, correlation: bestCorrelation)
    }
}

func generateClicks(outputURL: URL, duration: TimeInterval) throws {
    let sampleRate = 48_000.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let totalFrames = AVAudioFrameCount(duration * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
          let channel = buffer.floatChannelData?.pointee else {
        throw AlignmentError.unsupportedFormat("Could not allocate click buffer")
    }

    buffer.frameLength = totalFrames
    memset(channel, 0, Int(totalFrames) * MemoryLayout<Float>.size)

    // Short high-frequency clicks give a sharp correlation peak while staying
    // small enough not to dominate a room for the whole smoke run.
    let clickOffsets = stride(from: 1.0, to: max(1.0, duration - 0.5), by: 0.75)
    let clickLength = Int(sampleRate * 0.006)
    for offset in clickOffsets {
        let start = Int(offset * sampleRate)
        guard start + clickLength < Int(totalFrames) else { continue }
        for index in 0..<clickLength {
            let phase = Double(index) / Double(clickLength)
            let envelope = sin(.pi * phase)
            let sample = Float(0.85 * envelope * sin(2.0 * .pi * 1_800.0 * Double(index) / sampleRate))
            channel[start + index] = sample
        }
    }

    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let file = try AVAudioFile(
        forWriting: outputURL,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
    print(outputURL.path)
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw AlignmentError.invalidArgument(help)
    }

    switch command {
    case "generate-clicks":
        guard args.count >= 2 else { throw AlignmentError.invalidArgument(help) }
        let duration = args.count >= 3 ? (TimeInterval(args[2]) ?? 6) : 6
        try generateClicks(outputURL: URL(fileURLWithPath: args[1]), duration: duration)
    case "analyze":
        guard args.count >= 3 else { throw AlignmentError.invalidArgument(help) }
        let thresholdMS = args.count >= 4 ? (Int(args[3]) ?? 50) : 50
        let maxLagMS = args.count >= 5 ? (Int(args[4]) ?? 250) : 250
        let startDeltaMS = args.count >= 6 ? (Int(args[5]) ?? 0) : 0
        try analyze(
            micURL: URL(fileURLWithPath: args[1]),
            systemURL: URL(fileURLWithPath: args[2]),
            thresholdMS: thresholdMS,
            maxLagMS: maxLagMS,
            startDeltaMS: startDeltaMS
        )
    default:
        throw AlignmentError.invalidArgument(help)
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
