import XCTest
@testable import ChaosKit

final class ChaosKitTests: XCTestCase {
    func testGenerateIdPrefix() {
        let id = ChaosIDs.generateId()
        XCTAssertTrue(id.hasPrefix("ct_"))
    }

    func testSamplingStable() {
        let id = "ct_visitor_abc"
        let a = ChaosIDs.isSampledIn(visitorId: id, rate: 0.5)
        let b = ChaosIDs.isSampledIn(visitorId: id, rate: 0.5)
        XCTAssertEqual(a, b)
        XCTAssertTrue(ChaosIDs.isSampledIn(visitorId: id, rate: 1))
        XCTAssertFalse(ChaosIDs.isSampledIn(visitorId: id, rate: 0))
    }

    func testScreenClassify() {
        XCTAssertEqual(ChaosScreen.classify("Pricing"), .pricing)
        XCTAssertEqual(ChaosScreen.classify("Home"), .home)
        XCTAssertEqual(ChaosScreen.classify("CheckoutCart"), .checkout)
    }

    func testIntentAwarenessDefault() {
        let r = ChaosIntent.resolve(firedSignals: [])
        XCTAssertEqual(r.stage, .awareness)
    }

    func testIntentDecisionSignal() {
        let r = ChaosIntent.resolve(firedSignals: ["checkout_entered", "payment_reached"])
        XCTAssertEqual(r.stage, .decision)
    }

    func testTrackerLocalOnlyNoNetworkRequired() async {
        let mem = ChaosMemoryStorage()
        let tracker = await ChaosTracker.shared.start(
            config: ChaosConfig(
                siteId: "test",
                apiBase: "https://example.invalid/api/v1/intent",
                samplingRate: 1,
                localIntentOnly: true
            ),
            storage: mem
        )
        XCTAssertNotNil(tracker)
        tracker?.trackScreen("Home")
        tracker?.trackPress("cta_demo")
        let stage = tracker?.intent.rawValue
        XCTAssertEqual(stage, "awareness")
        tracker?.destroy()
    }
}
