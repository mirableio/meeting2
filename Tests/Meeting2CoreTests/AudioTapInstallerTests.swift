import AVFoundation
import Meeting2AudioSupport
import XCTest

/// A detached mixer graph needs no microphone permission or running audio device.
/// Installing a duplicate tap exercises the native graph failure that Swift cannot
/// catch directly; removing the first tap must leave the node usable for a retry.
final class AudioTapInstallerTests: XCTestCase {
    func testNativeTapFailureThrowsAndAllowsRetry() throws {
        let engine = AVAudioEngine()
        let node = AVAudioMixerNode()
        engine.attach(node)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try Meeting2AudioTapInstaller.install(on: node, bus: 0, bufferSize: 4096, format: format) { _, _ in }
        defer { node.removeTap(onBus: 0) }

        XCTAssertThrowsError(try Meeting2AudioTapInstaller.install(on: node, bus: 0, bufferSize: 4096, format: format) { _, _ in }) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        node.removeTap(onBus: 0)
        try Meeting2AudioTapInstaller.install(on: node, bus: 0, bufferSize: 4096, format: format) { _, _ in }
    }
}
