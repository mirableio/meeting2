@testable import Meeting2Core
import XCTest

/// The route classifier decides whether the mic could acoustically hear the call, which in
/// turn decides whether compression drops the (echo-duplicating) system track. Getting this
/// wrong toward "loudspeaker" risks losing the remote voice, so the bias is deliberate:
/// only the Mac's own built-in speakers count.
final class OutputRouteTests: XCTestCase {
    private func isLoudspeaker(transport: String?, dataSource: String? = nil, name: String? = nil) -> Bool {
        OutputRoute.classifyIsLoudspeaker(transport: transport, dataSourceName: dataSource, deviceName: name)
    }

    func testBuiltInSpeakersAreLoudspeaker() {
        XCTAssertTrue(isLoudspeaker(transport: "BuiltIn", dataSource: "Internal Speakers", name: "MacBook Pro Speakers"))
        // Common case: no data source exposed — a built-in output defaults to loudspeaker.
        XCTAssertTrue(isLoudspeaker(transport: "BuiltIn", dataSource: nil, name: "MacBook Pro Speakers"))
    }

    func testBuiltInHeadphoneJackIsNotLoudspeaker() {
        // Headphones present either as a data source or as a separate "External Headphones"
        // device, depending on the Mac — both must be ruled out.
        XCTAssertFalse(isLoudspeaker(transport: "BuiltIn", dataSource: "Headphones"))
        XCTAssertFalse(isLoudspeaker(transport: "BuiltIn", dataSource: nil, name: "External Headphones"))
    }

    func testExternalAndWirelessRoutesAreNotLoudspeaker() {
        XCTAssertFalse(isLoudspeaker(transport: "Bluetooth", name: "AirPods Pro"))
        XCTAssertFalse(isLoudspeaker(transport: "USB", name: "Jabra Headset"))
        XCTAssertFalse(isLoudspeaker(transport: "HDMI", name: "Studio Display"))
        XCTAssertFalse(isLoudspeaker(transport: "Virtual", name: "Some Virtual Device"))
        XCTAssertFalse(isLoudspeaker(transport: nil))
    }
}
