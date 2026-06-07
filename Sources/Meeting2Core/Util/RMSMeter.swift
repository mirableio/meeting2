import AVFoundation
import Foundation

// Measures how loud a track is (RMS = average level, peak = loudest sample). Its job
// is to catch the worst failure mode: a recording that *looks* complete — right size,
// right duration — but is actually silent (a dead tap, a revoked permission, a wrong
// audio route). A silent file is worse than an obvious error because you only discover
// it when you go looking for the meeting. Two cheap sums are enough to flag it; we
// deliberately keep this from growing into voice-activity detection or other DSP, which
// would add work to the recording path.
public struct RMSMeter {
    private(set) public var sampleCount: UInt64 = 0
    private(set) public var sumSquares: Double = 0
    private(set) public var peak: Float = 0
    /// A fast-attack, slow-release follower of recent loudness. Unlike cumulative `rms`
    /// (which barely moves once a recording is long), this tracks the last fraction of a
    /// second, so the UI can react to live audio (e.g. a breathing menu-bar indicator).
    private(set) public var recentLevel: Float = 0

    public init() {}

    public mutating func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?.pointee else { return }

        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var localPeak: Float = 0
        var localSum: Double = 0

        for index in 0..<frames {
            let sample = channel[index]
            localPeak = max(localPeak, abs(sample))
            localSum += Double(sample * sample)
        }

        sampleCount += UInt64(frames)
        sumSquares += localSum
        peak = max(peak, localPeak)

        // Jump up instantly to this buffer's level, decay gently otherwise — a calm
        // "breathing" signal that expands on sound and settles in quiet, never jumpy.
        let bufferRMS = Float((localSum / Double(frames)).squareRoot())
        recentLevel = max(bufferRMS, recentLevel * 0.82)
    }

    public var rms: Double {
        guard sampleCount > 0 else { return 0 }
        return sqrt(sumSquares / Double(sampleCount))
    }

    public var snapshot: RMSMeterSnapshot {
        RMSMeterSnapshot(sampleCount: sampleCount, sumSquares: sumSquares, peak: peak, recentLevel: recentLevel)
    }

    // Both the average level and the single loudest sample must be near zero, so one
    // stray click can't hide an otherwise-dead track. The thresholds sit below the
    // noise floor of any real capture, which is orders of magnitude louder.
    public var isSilent: Bool {
        rms < 0.000_001 && peak < 0.000_01
    }
}

public struct RMSMeterSnapshot {
    public let sampleCount: UInt64
    public let sumSquares: Double
    public let peak: Float
    public let recentLevel: Float

    public var rms: Double {
        guard sampleCount > 0 else { return 0 }
        return sqrt(sumSquares / Double(sampleCount))
    }

    public var isSilent: Bool {
        rms < 0.000_001 && peak < 0.000_01
    }
}

final class LockedRMSMeter {
    // RMS is advisory telemetry, but it is produced on capture/writer callbacks and
    // consumed by UI health checks. Keep that bridge explicit: a very short lock around
    // three scalar values avoids data races without ever touching Core Audio's IOProc.
    private let lock = NSLock()
    private var meter = RMSMeter()

    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        meter.ingest(buffer)
        lock.unlock()
    }

    var snapshot: RMSMeterSnapshot {
        lock.lock()
        let snapshot = meter.snapshot
        lock.unlock()
        return snapshot
    }
}
