import XCTest
@testable import ChaosKit

// MARK: - Test doubles

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}

private final class StubTransport: ChaosTransport, @unchecked Sendable {
    enum Reply {
        case status(Int)
        case offline
    }

    private let lock = NSLock()
    private var reply: Reply = .status(200)
    private var _requests: [URLRequest] = []
    private var _events: [[String: Any]] = []

    func set(_ reply: Reply) {
        lock.lock(); defer { lock.unlock() }
        self.reply = reply
    }

    /// Number of `/ingest` calls attempted.
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requests.count
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    /// Events from batches the stub answered with 2xx, in delivery order.
    var delivered: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    func delivered(ofType type: String) -> [[String: Any]] {
        delivered.filter { $0["type"] as? String == type }
    }

    private func record(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        if case .status(let code) = reply, (200..<300).contains(code),
           let body = request.httpBody,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let batch = obj["batch"] as? [[String: Any]] {
            _events.append(contentsOf: batch)
        }
        return reply
    }

    func send(_ request: URLRequest) async throws -> Int {
        switch record(request) {
        case .status(let code): return code
        case .offline: throw URLError(.notConnectedToInternet)
        }
    }
}

// MARK: - Tests

final class TrackerTests: XCTestCase {
    private var clock: TestClock!
    private var transport: StubTransport!
    private var storage: ChaosMemoryStorage!
    private var tracker: ChaosTracker!

    override func setUp() {
        clock = TestClock()
        transport = StubTransport()
        storage = ChaosMemoryStorage()
        let clock = self.clock!
        tracker = ChaosTracker(transport: transport, now: { clock.now }, usesTimers: false)
    }

    override func tearDown() {
        tracker.destroy()
    }

    private func start(localIntentOnly: Bool = false, hashIdentifiers: Bool = false) async {
        let started = await tracker.start(
            config: ChaosConfig(
                siteId: "test",
                apiBase: "https://example.invalid/api/v1/intent/",
                apiKey: "k",
                hashIdentifiers: hashIdentifiers,
                localIntentOnly: localIntentOnly
            ),
            storage: storage
        )
        XCTAssertNotNil(started)
        await settle()
    }

    /// Flush until nothing is queued or in flight (start() also kicks off a flush).
    private func settle() async {
        for _ in 0..<200 {
            await tracker.flush()
            if tracker.isQuiescent { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("tracker did not settle")
    }

    private func pendingEvents() -> [ChaosEvent] {
        guard let raw = storage.get(ChaosCore.pendingBufferKey),
              let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChaosEvent].self, from: data)) ?? []
    }

    private func firedSignals() -> Set<String> {
        guard case .array(let items)? = tracker.intentSnapshot["signals_fired"] else { return [] }
        return Set(items.compactMap { if case .string(let s) = $0 { return s } else { return nil } })
    }

    // MARK: Flush

    func testFlushDeliversEventsAndLeavesNothingPending() async {
        await start()
        tracker.trackScreen("Live")
        await settle()

        XCTAssertEqual(transport.delivered(ofType: "session_start").count, 1)
        let views = transport.delivered(ofType: "screen_view")
        XCTAssertEqual(views.count, 1)
        XCTAssertEqual(views.first?["site_id"] as? String, "test")
        XCTAssertEqual(views.first?["platform"] as? String, "ios")
        XCTAssertNil(storage.get(ChaosCore.pendingBufferKey))

        let request = transport.requests.first
        XCTAssertEqual(request?.url?.absoluteString, "https://example.invalid/api/v1/intent/ingest")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testTransportFailureKeepsEventsPendingThenDeliversThem() async {
        transport.set(.offline)
        await start()
        tracker.trackPress("shutter")
        await settle()

        let pending = pendingEvents()
        XCTAssertTrue(pending.contains { $0.type == "press" })
        XCTAssertTrue(transport.delivered.isEmpty)

        transport.set(.status(200))
        await settle()
        let deliveredIds = Set(transport.delivered.compactMap { $0["event_id"] as? String })
        XCTAssertEqual(deliveredIds, Set(pending.map(\.eventId)))
        XCTAssertNil(storage.get(ChaosCore.pendingBufferKey))
    }

    func testServerErrorAndRateLimitAreRetried() async {
        for code in [500, 429, 408] {
            transport.set(.status(code))
            await start()
            XCTAssertFalse(pendingEvents().isEmpty, "status \(code) must keep events")
            tracker.destroy()
            storage = ChaosMemoryStorage()
        }
    }

    func testClientErrorDropsBatchInsteadOfRetrying() async {
        transport.set(.status(401))
        await start()
        tracker.trackPress("shutter")
        await settle()

        XCTAssertTrue(pendingEvents().isEmpty)
        let calls = transport.callCount
        XCTAssertGreaterThan(calls, 0)

        // Nothing left to resend.
        await settle()
        XCTAssertEqual(transport.callCount, calls)
    }

    func testBackoffDoublesAndIsCapped() {
        XCTAssertEqual(ChaosTracker.backoff(afterFailures: 0), 0)
        XCTAssertEqual(ChaosTracker.backoff(afterFailures: 1), 5)
        XCTAssertEqual(ChaosTracker.backoff(afterFailures: 2), 10)
        XCTAssertEqual(ChaosTracker.backoff(afterFailures: 3), 20)
        XCTAssertEqual(ChaosTracker.backoff(afterFailures: 50), ChaosCore.maxFlushBackoff)
    }

    func testConcurrentTrackAndFlushDeliversEveryEventOnce() async {
        await start()
        let tracker = self.tracker!
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for i in 0..<200 {
                        tracker.track(type: "load", data: ["w": worker, "i": i])
                        if i % 25 == 0 { await tracker.flush() }
                    }
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    tracker.heartbeatTick()
                    _ = tracker.intentSnapshot
                    await tracker.flush()
                }
            }
        }
        await settle()

        let ids = transport.delivered(ofType: "load").compactMap { $0["event_id"] as? String }
        XCTAssertEqual(ids.count, 1600)
        XCTAssertEqual(Set(ids).count, 1600)
        XCTAssertNil(storage.get(ChaosCore.pendingBufferKey))
    }

    // MARK: Sessions

    func testExpiredSessionEndCarriesPreviousSessionId() async throws {
        let stale = (clock.now.timeIntervalSince1970 - ChaosCore.sessionTTL - 60) * 1000
        storage.set(ChaosCore.sessionKey, #"{"id":"ct_old","ts":\#(stale),"start":\#(stale)}"#)
        await start()

        let types = transport.delivered.compactMap { $0["type"] as? String }
        let endIndex = try XCTUnwrap(types.firstIndex(of: "session_end"))
        let startIndex = try XCTUnwrap(types.firstIndex(of: "session_start"))
        XCTAssertLessThan(endIndex, startIndex)

        let end = transport.delivered[endIndex]
        let begin = transport.delivered[startIndex]
        XCTAssertEqual(end["session_id"] as? String, "ct_old")
        XCTAssertNotEqual(begin["session_id"] as? String, "ct_old")
        XCTAssertEqual((end["data"] as? [String: Any])?["reason"] as? String, "ttl_expired")
    }

    func testLiveSessionIsResumedWithoutSessionEnd() async {
        let recent = (clock.now.timeIntervalSince1970 - 60) * 1000
        storage.set(ChaosCore.sessionKey, #"{"id":"ct_live","ts":\#(recent),"start":\#(recent)}"#)
        await start()

        XCTAssertTrue(transport.delivered(ofType: "session_end").isEmpty)
        XCTAssertEqual(transport.delivered(ofType: "session_start").first?["session_id"] as? String, "ct_live")
    }

    func testActivityRefreshesStoredSessionTimestamp() async throws {
        await start()
        clock.advance(ChaosCore.sessionTouchInterval + 10)
        tracker.trackPress("shutter")

        let raw = try XCTUnwrap(storage.get(ChaosCore.sessionKey))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let ts = try XCTUnwrap(obj["ts"] as? Double)
        XCTAssertEqual(ts, clock.now.timeIntervalSince1970 * 1000, accuracy: 1)
    }

    func testForegroundAfterTTLRotatesSession() async throws {
        await start()
        let firstId = try XCTUnwrap(transport.delivered(ofType: "session_start").first?["session_id"] as? String)

        tracker.handleDidEnterBackground()
        clock.advance(ChaosCore.sessionTTL + 60)
        tracker.handleWillEnterForeground()
        await settle()

        let ends = transport.delivered(ofType: "session_end")
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends.first?["session_id"] as? String, firstId)
        XCTAssertEqual((ends.first?["data"] as? [String: Any])?["reason"] as? String, "ttl_expired_on_resume")

        let starts = transport.delivered(ofType: "session_start")
        XCTAssertEqual(starts.count, 2)
        XCTAssertNotEqual(starts.last?["session_id"] as? String, firstId)
    }

    func testShortBackgroundKeepsSession() async {
        await start()
        tracker.handleDidEnterBackground()
        clock.advance(120)
        tracker.handleWillEnterForeground()
        await settle()
        XCTAssertTrue(transport.delivered(ofType: "session_end").isEmpty)
        XCTAssertEqual(transport.delivered(ofType: "session_start").count, 1)
    }

    // MARK: Privacy

    func testOptOutStopsSendingAndClearsPending() async {
        transport.set(.offline)
        await start()
        tracker.trackPress("shutter")
        await settle()
        XCTAssertFalse(pendingEvents().isEmpty)

        tracker.optOut()
        XCTAssertNil(storage.get(ChaosCore.pendingBufferKey))

        transport.set(.status(200))
        let calls = transport.callCount
        tracker.trackPress("shutter")
        await tracker.flush()
        XCTAssertEqual(transport.callCount, calls)
        XCTAssertTrue(transport.delivered.isEmpty)

        tracker.destroy()
        let restarted = await tracker.start(config: ChaosConfig(siteId: "test"), storage: storage)
        XCTAssertNil(restarted, "opt-out must survive a restart")
    }

    func testLocalIntentOnlySendsOnlySnapshotsAndIdentify() async {
        await start(localIntentOnly: true)
        tracker.trackScreen("Live")
        tracker.trackPress("shutter")
        tracker.trackForm("lead", action: .start)
        tracker.track(type: "custom", data: ["a": 1])
        tracker.identify(["plan": "demo"])
        tracker.handleDidEnterBackground()
        tracker.handleWillEnterForeground()
        await settle()

        let types = Set(transport.delivered.compactMap { $0["type"] as? String })
        XCTAssertEqual(types, ["intent_snapshot", "identify"])
    }

    func testHashIdentifiersSendsDigestNotPlaintext() async throws {
        await start(hashIdentifiers: true)
        tracker.identify(["email": "a@b.c", "plan": "demo"])
        await settle()

        let identify = try XCTUnwrap(transport.delivered(ofType: "identify").first)
        let traits = try XCTUnwrap((identify["data"] as? [String: Any])?["traits"] as? [String: Any])
        XCTAssertEqual(traits["plan"] as? String, "demo")
        XCTAssertEqual(traits["email"] as? String, ChaosTracker.sha256Hex("a@b.c"))
        XCTAssertEqual(
            ChaosTracker.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: Signals

    func testHeartbeatFiresDwellSignalWithoutFurtherInteraction() async {
        await start()
        tracker.trackScreen("Pricing")
        XCTAssertFalse(firedSignals().contains("pricing_over_30s"))

        clock.advance(31)
        tracker.heartbeatTick()
        XCTAssertTrue(firedSignals().contains("pricing_over_30s"))

        await settle()
        let signals = transport.delivered(ofType: "signal").compactMap {
            ($0["data"] as? [String: Any])?["signal"] as? String
        }
        XCTAssertTrue(signals.contains("pricing_over_30s"))
        XCTAssertEqual(transport.delivered(ofType: "heartbeat").count, 1)
    }

    func testLocalHeartbeatEmitsSnapshotOnlyWhenIntentChanges() async {
        await start(localIntentOnly: true)
        tracker.trackScreen("Pricing")
        await settle()
        let baseline = transport.delivered(ofType: "intent_snapshot").count

        tracker.heartbeatTick()
        tracker.heartbeatTick()
        await settle()
        XCTAssertEqual(transport.delivered(ofType: "intent_snapshot").count, baseline)

        clock.advance(31)          // pricing_over_30s becomes true
        tracker.heartbeatTick()
        tracker.heartbeatTick()
        await settle()
        XCTAssertEqual(transport.delivered(ofType: "intent_snapshot").count, baseline + 1)
    }

    func testHomeBounceFiresOnQuickExitOnly() async {
        await start()
        tracker.trackScreen("Home")
        XCTAssertFalse(firedSignals().contains("homepage_under_20s"), "viewing Home is not a bounce")

        clock.advance(5)
        tracker.trackScreen("Live")
        XCTAssertTrue(firedSignals().contains("homepage_under_20s"))
    }

    func testLongHomeVisitIsNotABounce() async {
        await start()
        tracker.trackScreen("Home")
        clock.advance(25)
        tracker.trackScreen("Live")
        XCTAssertFalse(firedSignals().contains("homepage_under_20s"))
    }

    // MARK: Constants and version

    @available(*, deprecated)
    func testDeprecatedMillisecondAliasesStillResolve() {
        XCTAssertEqual(ChaosCore.flushIntervalMs, ChaosCore.flushInterval)
        XCTAssertEqual(ChaosCore.heartbeatMs, ChaosCore.heartbeatInterval)
        XCTAssertEqual(ChaosCore.sessionTTLMs, ChaosCore.sessionTTL)
        XCTAssertEqual(ChaosCore.intentHalfLifeMs, ChaosCore.intentHalfLife)
        XCTAssertEqual(ChaosCore.blurAbandonThresholdMs, ChaosCore.backgroundAbandonThreshold)
    }

    func testChangelogHasEntryForCurrentVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        XCTAssertTrue(
            changelog.contains("## [\(ChaosKitModule.version)]"),
            "CHANGELOG.md needs an entry for \(ChaosKitModule.version)"
        )
    }

    func testPrivacyManifestIsBundled() {
        XCTAssertNotNil(ChaosKitModule.privacyManifestURL)
    }
}
