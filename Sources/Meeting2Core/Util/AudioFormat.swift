import AVFoundation

public enum AudioFormat {
    // Every captured sample is converted to this one fixed format before being written.
    // The audio hardware's own format can change mid-recording (plug in headphones and
    // the sample rate may switch), but a file's format is fixed when it's opened — so we
    // pin one format here. Mono because speech doesn't need stereo; 48 kHz/float because
    // that's the process tap's natural format. Both files sharing it also keeps them
    // trivially comparable when lining the two recordings up in time.
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 1

    public static let pcmFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }()

    public static var cafSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]
    }
}

extension AVAudioFormat {
    func isEquivalent(to other: AVAudioFormat) -> Bool {
        commonFormat == other.commonFormat &&
            sampleRate == other.sampleRate &&
            channelCount == other.channelCount &&
            isInterleaved == other.isInterleaved
    }
}
