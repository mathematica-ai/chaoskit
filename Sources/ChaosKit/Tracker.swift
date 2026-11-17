import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Event

public struct ChaosEvent: Codable, Sendable {
    public var eventId: String
    public var type: String
    public var ts: Int64
    public var visitorId: String
    public var sessionId: String
    public var siteId: String?
    public var platform: String
    public var platformVersion: String?
    public var screen: String?
    public var data: [String: ChaosJSON]

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case type, ts
        case visitorId = "visitor_id"
        case sessionId = "session_id"
        case siteId = "site_id"
        case platform
        case platformVersion = "platform_version"
        case screen, data
    }
}

/// Lightweight JSON value for heterogeneous event payloads.
public enum ChaosJSON: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ChaosJSON])
    case array([ChaosJSON])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .number(Double(i)); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: ChaosJSON].self) { self = .object(o); return }
        if let a = try? c.decode([ChaosJSON].self) { self = .array(a); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public static func from(_ any: Any?) -> ChaosJSON {
        switch any {
        case nil: return .null
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .number(Double(i))
        case let d as Double: return .number(d)
        case let f as Float: return .number(Double(f))
        case let dict as [String: Any]:
            return .object(dict.mapValues { from($0) })
        case let arr as [Any]:
            return .array(arr.map { from($0) })
        default:
            return .string(String(describing: any!))
        }
    }
}

// MARK: - Transport

/// Delivers one `/ingest` request and returns the HTTP status code. Throws on
/// transport failure (offline, timeout, TLS). Injectable so tests never touch
/// the network.
protocol ChaosTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Int
}

struct ChaosURLSessionTransport: ChaosTransport {
    func send(_ request: URLRequest) async throws -> Int {
        let (_, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http.statusCode
    }
}

// MARK: - Tracker

/// Native iOS port of `p1-chaos-tracker/native` — intent-aware anonymous analytics.
///
/// Wire into SwiftUI / UIKit:
/// ```swift
/// let tracker = await ChaosTracker.shared.start(config: .init(
///     siteId: "p1-vision",
///     apiBase: "https://ap1.mathematica.ai/api/v1/intent",
///     localIntentOnly: true  // recommended for privacy-first apps
/// ))
/// tracker?.trackScreen("Live")
/// tracker?.trackPress("shutter_photo")
/// ```
///
/// **Thread safety.** Every piece of mutable state below is read and written
/// only while `lock` is held. Methods suffixed `Locked` require the caller to
/// hold it; public entry points take it once and never across an `await`.
/// Network sends happen outside the lock, and flushes are single-flight.
public final class ChaosTracker: @unchecked Sendable {
    public static let shared = ChaosTracker()

    private let lock = NSLock()
    private let transport: ChaosTransport
    private let now: @Sendable () -> Date
    private let usesTimers: Bool
    private let timerQueue = DispatchQueue(label: "ai.mathematica.chaoskit.timers", qos: .utility)

    private var storage: ChaosStoring = ChaosUserDefaultsStorage()
    private var config = ChaosConfig()
    private var active = false
    private var stopped = false

    private var visitorId = ""
    private var sessionId = ""
    private var sessionStart = Date()
    private var siteId: String?
    private var systemVersion: String?
    private var deviceInfo: [String: ChaosJSON] = [:]
    private var pagesViewed = 0
    private var visitCount = 0
    private var currentScreen: String?
    private var screenEntryTime = Date()
    private var queue: [ChaosEvent] = []
    private var firedSignals = Set<String>()
    private var firedAt: [String: Date] = [:]
    private var signalSequence: [(s: String, t: Date)] = []
    private var stageHistory: [(stage: IntentStage, at: Date)] = []
    private var currentIntent: IntentStage = .awareness
    private var lastIntent = ChaosIntent.resolve(firedSignals: [])
    private var priorIntentScores: [IntentStage: Double]?
    private var attribution: [String: ChaosJSON] = [:]
    private var lastSnapshotKey: String?

    private var flushTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var observing = false

    private var isFlushing = false
    private var flushRequestedAgain = false
    private var consecutiveFlushFailures = 0
    private var nextFlushAllowedAt: Date?

    private var lastActivityAt = Date()
    private var lastSessionTouchAt = Date()
    private var backgroundCount = 0
    private var totalBackground: TimeInterval = 0
    private var lastBackgroundAt: Date?
    private var appInBackground = false

    private let localAllowed: Set<String> = ["intent_snapshot", "identify"]

    /// `shared` is the production instance. Tests build isolated instances
    /// with a stub transport, a controllable clock and timers off.
    init(
        transport: ChaosTransport = ChaosURLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() },
        usesTimers: Bool = true
    ) {
        self.transport = transport
        self.now = now
        self.usesTimers = usesTimers
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Lifecycle

    /// Start (or return) the tracker. Returns `nil` when consent/sampling rejects.
    @discardableResult
    public func start(config: ChaosConfig, storage customStorage: ChaosStoring? = nil) async -> ChaosTracker? {
        if locked({ active && !stopped }) { return self }

        let store = customStorage ?? locked { storage }
        let signals = ChaosPrivacySignals(
            gpc: false,
            dnt: false,
            optedOut: store.get(ChaosCore.optOutKey) == "1"
        )
        if signals.optedOut { return nil }
        if let consent = config.hasConsent, !consent(signals) { return nil }

        let vid = Self.resolveVisitorId(store)
        if !ChaosIDs.isSampledIn(visitorId: vid, rate: config.samplingRate) {
            return nil
        }

        // Assessed ONCE: one verdict fills all three fields.
        let botAssessment = ChaosBot.assess(userAgent: config.userAgent)
        var device: [String: ChaosJSON] = [
            "platform": .string("ios"),
            "bot_assessment": .object([
                "flags": .object(botAssessment.flags.mapValues { .bool($0) }),
                "score": .number(Double(botAssessment.score)),
                "is_likely_bot": .bool(botAssessment.isLikelyBot),
            ]),
        ]
        if let ua = config.userAgent {
            device["user_agent"] = .string(ua)
        }
        var osVersion: String?
#if canImport(UIKit)
        // `UIDevice.current` is @MainActor-isolated. It is read here, once, in
        // a single hop; `enqueue` reuses the captured version so tracking
        // calls from any thread never touch UIKit.
        let deviceIdentity = await MainActor.run {
            (model: UIDevice.current.model, systemVersion: UIDevice.current.systemVersion)
        }
        device["model"] = .string(deviceIdentity.model)
        device["system_version"] = .string(deviceIdentity.systemVersion)
        osVersion = deviceIdentity.systemVersion
#endif

        let startedNow: Bool = locked {
            // Another start() won the race while this one was suspended.
            if active && !stopped { return false }

            let t = now()
            storage = store
            self.config = config
            visitorId = vid
            siteId = config.siteId
            systemVersion = osVersion
            deviceInfo = device

            let session = resolveSessionLocked(at: t)
            visitCount = incrementVisitCountLocked(at: t)
            pagesViewed = Int(storage.get(ChaosCore.pagesKey) ?? "0") ?? 0
            priorIntentScores = loadIntentProfileLocked(at: t)
            attribution = resolveAttributionLocked(config.initialAttribution, at: t)
            currentIntent = .awareness
            firedSignals = []
            firedAt = [:]
            signalSequence = []
            queue = []
            lastSnapshotKey = nil
            consecutiveFlushFailures = 0
            nextFlushAllowedAt = nil
            lastActivityAt = t
            lastSessionTouchAt = t
            stopped = false
            active = true

            // The expired session is closed under ITS id, before the new one opens.
            if session.previousExpired, let previous = session.previousId {
                enqueueLocked("session_end", data: ["reason": .string("ttl_expired")], sessionId: previous)
            }
            sessionId = session.id
            sessionStart = session.start
            stageHistory = [(stage: .awareness, at: sessionStart)]
            enqueueLocked("session_start", data: sessionStartPayloadLocked(isNew: session.isNew))

            if storage.get(ChaosCore.cartActiveKey) == "1" {
                fireSignalLocked("abandoned_cart", meta: nil)
            }
            startTimersLocked()
            return true
        }

        if startedNow {
            observeAppLifecycle()
            Task { await flush() }
        }
        return self
    }

    public func destroy() {
        let wasObserving: Bool = locked {
            cancelTimersLocked()
            active = false
            stopped = true
            queue.removeAll()
            let was = observing
            observing = false
            return was
        }
        if wasObserving {
            NotificationCenter.default.removeObserver(self)
        }
    }

    public func optOut() {
        locked {
            storage.set(ChaosCore.optOutKey, "1")
            stopped = true
            queue.removeAll()
            storage.remove(ChaosCore.pendingBufferKey)
        }
    }

    public func optIn() {
        locked {
            storage.remove(ChaosCore.optOutKey)
            stopped = false
        }
    }

    // MARK: Tracking API

    public func trackScreen(_ name: String, params: [String: Any]? = nil) {
        locked {
            guard isRunnableLocked else { return }
            let t = now()
            touchLocked(at: t)
            if let prev = currentScreen {
                let secs = Int(t.timeIntervalSince(screenEntryTime))
                enqueueLocked("screen_exit", data: [
                    "screen": .string(prev),
                    "time_on_screen": .number(Double(secs)),
                ])
                fireHomeBounceIfNeededLocked(at: t)
            }
            currentScreen = name
            screenEntryTime = t
            pagesViewed += 1
            storage.set(ChaosCore.pagesKey, String(pagesViewed))

            enqueueLocked("screen_view", data: [
                "screen": .string(name),
                "screen_type": .string(ChaosScreen.classify(name).rawValue),
                "pages_viewed": .number(Double(pagesViewed)),
                "params": ChaosJSON.from(params),
                "attribution": .object(attribution),
            ])
            evaluateSignalsLocked(at: t)
            emitIntentSnapshotLocked(onlyIfChanged: false)
        }
    }

    public func trackPress(_ name: String, meta: [String: Any]? = nil) {
        locked {
            guard isRunnableLocked else { return }
            let t = now()
            touchLocked(at: t)
            enqueueLocked("press", data: [
                "track": .string(name),
                "screen_type": .string(ChaosScreen.classify(currentScreen).rawValue),
                "meta": ChaosJSON.from(meta),
            ])
            let lower = name.lowercased()
            if lower.contains("pricing") || lower.contains("compare") {
                fireSignalLocked("comparison_click", meta: nil)
            }
            if lower.contains("checkout") || lower.contains("buy") {
                fireSignalLocked("checkout_entered", meta: nil)
            }
            evaluateSignalsLocked(at: t)
            emitIntentSnapshotLocked(onlyIfChanged: false)
        }
    }

    public func trackForm(_ name: String, action: ChaosFormAction, type: String? = nil) {
        locked {
            guard isRunnableLocked else { return }
            let t = now()
            touchLocked(at: t)
            enqueueLocked("form", data: [
                "name": .string(name),
                "action": .string(action.rawValue),
                "form_type": .string(type ?? "unknown"),
            ])
            switch action {
            case .start: fireSignalLocked("demo_form_start", meta: nil)
            case .abandon: fireSignalLocked("form_abandon", meta: nil)
            case .submit: break
            }
            evaluateSignalsLocked(at: t)
            emitIntentSnapshotLocked(onlyIfChanged: false)
        }
    }

    public func track(type: String, data: [String: Any]? = nil) {
        var payload: [String: ChaosJSON] = [:]
        if let data {
            for (k, v) in data { payload[k] = ChaosJSON.from(v) }
        }
        locked {
            guard isRunnableLocked else { return }
            touchLocked(at: now())
            enqueueLocked(type, data: payload)
        }
    }

    /// Sends traits. With `config.hashIdentifiers`, fields listed in
    /// `config.hashFields` are replaced by their SHA-256 hex digest.
    public func identify(_ traits: [String: String]) {
        locked {
            guard isRunnableLocked else { return }
            var out: [String: ChaosJSON] = [:]
            for (k, v) in traits {
                if config.hashIdentifiers, config.hashFields.contains(k) {
                    // Fail closed: if hashing is unavailable the field is dropped.
                    if let digest = Self.sha256Hex(v) { out[k] = .string(digest) }
                    continue
                }
                out[k] = .string(v)
            }
            enqueueLocked("identify", data: ["traits": .object(out)])
        }
    }

    public func fireSignal(_ signal: String, meta: [String: Any]? = nil) {
        locked {
            guard isRunnableLocked else { return }
            fireSignalLocked(signal, meta: meta)
        }
    }

    public var intent: IntentStage {
        locked { currentIntent }
    }

    public var intentSnapshot: [String: ChaosJSON] {
        locked {
            resolveIntentLocked()
            return snapshotLocked()
        }
    }

    // MARK: Flush

    /// Upload queued events now. Ignores retry backoff (the periodic timer
    /// honours it). Single-flight: a call made while a flush is in progress
    /// returns at once and the running flush does one more pass.
    public func flush() async {
        await runFlush(force: true)
    }

    private func runFlush(force: Bool) async {
        let proceed: Bool = locked {
            if stopped { return false }
            if isFlushing {
                flushRequestedAgain = true
                return false
            }
            if !force, let next = nextFlushAllowedAt, now() < next { return false }
            isFlushing = true
            return true
        }
        guard proceed else { return }

        while true {
            let delivered = await drainOnce()
            let again: Bool = locked {
                if delivered, flushRequestedAgain, !stopped {
                    flushRequestedAgain = false
                    return true
                }
                flushRequestedAgain = false
                isFlushing = false
                return false
            }
            if !again { break }
        }
    }

    private enum SendOutcome {
        case delivered
        /// Server refused the batch for good (4xx other than 408/429) — drop it.
        case rejected
        /// Transport error, 408, 429 or 5xx — keep it and back off.
        case retry
    }

    private struct FlushWork {
        var batches: [[ChaosEvent]]
        var apiBase: String
        var apiKey: String?
        var intent: String
        var visitorId: String
        var sessionId: String
        var siteId: String?
    }

    /// One pass over the pending buffer + in-memory queue. Returns `false`
    /// when a batch has to be retried later.
    private func drainOnce() async -> Bool {
        let work: FlushWork? = locked {
            if stopped { return nil }
            let all = loadPendingLocked() + queue
            queue.removeAll()
            guard !all.isEmpty else { return nil }
            // Everything in flight is on disk until the server acknowledges it,
            // so a process kill mid-send does not lose events.
            savePendingLocked(Array(all.suffix(ChaosCore.maxPendingBufferSize)))
            var batches: [[ChaosEvent]] = []
            var i = 0
            while i < all.count {
                let end = min(i + ChaosCore.maxBatchSize, all.count)
                batches.append(Array(all[i..<end]))
                i = end
            }
            return FlushWork(
                batches: batches,
                apiBase: config.apiBase,
                apiKey: config.apiKey,
                intent: currentIntent.rawValue,
                visitorId: visitorId,
                sessionId: sessionId,
                siteId: siteId
            )
        }
        guard let work else { return true }

        for (index, batch) in work.batches.enumerated() {
            let outcome = await sendBatch(batch, work: work)
            switch outcome {
            case .delivered, .rejected:
                let ids = Set(batch.map(\.eventId))
                locked {
                    guard !stopped else { return }
                    let rest = loadPendingLocked().filter { !ids.contains($0.eventId) }
                    if rest.isEmpty { storage.remove(ChaosCore.pendingBufferKey) } else { savePendingLocked(rest) }
                }
            case .retry:
                let unsent = work.batches[index...].flatMap { $0 }
                locked {
                    guard !stopped else { return }
                    var pending = loadPendingLocked()
                    let known = Set(pending.map(\.eventId))
                    pending.append(contentsOf: unsent.filter { !known.contains($0.eventId) })
                    if pending.count > ChaosCore.maxPendingBufferSize {
                        pending = Array(pending.suffix(ChaosCore.maxPendingBufferSize))
                    }
                    savePendingLocked(pending)
                    consecutiveFlushFailures += 1
                    nextFlushAllowedAt = now().addingTimeInterval(
                        Self.backoff(afterFailures: consecutiveFlushFailures)
                    )
                }
                return false
            }
        }
        locked {
            consecutiveFlushFailures = 0
            nextFlushAllowedAt = nil
        }
        return true
    }

    /// `flushInterval * 2^(failures-1)`, capped at `maxFlushBackoff`.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 16))
        return min(ChaosCore.maxFlushBackoff, ChaosCore.flushInterval * pow(2, exponent))
    }

    private func sendBatch(_ batch: [ChaosEvent], work: FlushWork) async -> SendOutcome {
        var base = work.apiBase
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/ingest") else { return .retry }
        struct Body: Encodable {
            var batch: [ChaosEvent]
            var intent: String
            var visitor_id: String
            var session_id: String
            var site_id: String?
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = work.apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let payload = try? JSONEncoder().encode(
            Body(batch: batch, intent: work.intent, visitor_id: work.visitorId,
                 session_id: work.sessionId, site_id: work.siteId)
        ) else { return .rejected }
        req.httpBody = payload

        let status: Int
        do {
            status = try await transport.send(req)
        } catch {
            return .retry
        }
        switch status {
        case 200..<300: return .delivered
        case 408, 429: return .retry
        case 400..<500: return .rejected
        default: return .retry
        }
    }

    // MARK: - Internals (lock must be held)

    private var isRunnableLocked: Bool { active && !stopped }

    private func timeOnScreenLocked(at t: Date) -> Int {
        Int(t.timeIntervalSince(screenEntryTime))
    }

    private func sessionDurationLocked(at t: Date) -> Int {
        Int(t.timeIntervalSince(sessionStart))
    }

    /// Records user activity and keeps the stored session alive. The storage
    /// write is throttled to once per `sessionTouchInterval`.
    private func touchLocked(at t: Date) {
        lastActivityAt = t
        if t.timeIntervalSince(lastSessionTouchAt) >= ChaosCore.sessionTouchInterval {
            lastSessionTouchAt = t
            persistSessionLocked(id: sessionId, start: sessionStart, touchedAt: t)
        }
    }

    private func enqueueLocked(_ type: String, data: [String: ChaosJSON], sessionId overrideSessionId: String? = nil) {
        guard active, !stopped else { return }
        if config.localIntentOnly, !localAllowed.contains(type) { return }
        let event = ChaosEvent(
            eventId: ChaosIDs.generateId(),
            type: type,
            ts: Int64(now().timeIntervalSince1970 * 1000),
            visitorId: visitorId,
            sessionId: overrideSessionId ?? sessionId,
            siteId: siteId,
            platform: "ios",
            platformVersion: systemVersion,
            screen: currentScreen,
            data: data
        )
        queue.append(event)
    }

    private func sessionStartPayloadLocked(isNew: Bool) -> [String: ChaosJSON] {
        [
            "visit_count": .number(Double(visitCount)),
            "is_new_session": .bool(isNew),
            "device": .object(deviceInfo),
            "attribution": .object(attribution),
            "storage_persistent": .bool(storage.isPersistent),
        ]
    }

    private func fireSignalLocked(_ signal: String, meta: [String: Any]?) {
        guard !firedSignals.contains(signal) else { return }
        let t = now()
        firedSignals.insert(signal)
        firedAt[signal] = t
        signalSequence.append((s: signal, t: t))

        let stage = resolveIntentLocked()
        enqueueLocked("signal", data: [
            "signal": .string(signal),
            "intent_stage": .string(stage.rawValue),
            "screen_type": .string(ChaosScreen.classify(currentScreen).rawValue),
            "time_on_screen": .number(Double(timeOnScreenLocked(at: t))),
            "session_duration": .number(Double(sessionDurationLocked(at: t))),
            "pages_viewed": .number(Double(pagesViewed)),
            "attribution": .object(attribution),
            "meta": ChaosJSON.from(meta),
        ])
    }

    @discardableResult
    private func resolveIntentLocked() -> IntentStage {
        let t = now()
        let result = ChaosIntent.resolve(
            firedSignals: firedSignals,
            firedAt: firedAt,
            now: t,
            priorScores: priorIntentScores
        )
        lastIntent = result
        if result.stage != currentIntent {
            currentIntent = result.stage
            stageHistory.append((stage: currentIntent, at: t))
        }
        saveIntentProfileLocked(result.scores, at: t)
        return currentIntent
    }

    private func snapshotLocked() -> [String: ChaosJSON] {
        let t = now()
        let entered = stageHistory.last?.at ?? sessionStart
        return [
            "stage": .string(currentIntent.rawValue),
            "score": .number(lastIntent.score),
            "confidence": .number(lastIntent.confidence),
            "frustrated": .bool(lastIntent.frustrated),
            "session_duration": .number(Double(sessionDurationLocked(at: t))),
            "pages_viewed": .number(Double(pagesViewed)),
            "screen": currentScreen.map { .string($0) } ?? .null,
            "time_to_current_stage_ms": .number(max(0, entered.timeIntervalSince(sessionStart) * 1000)),
            "signal_sequence": .array(signalSequence.map { .string($0.s) }),
            "signals_fired": .array(firedSignals.sorted().map { .string($0) }),
        ]
    }

    /// `localIntentOnly` only. With `onlyIfChanged`, nothing is sent unless the
    /// stage or the set of fired signals moved since the last snapshot.
    private func emitIntentSnapshotLocked(onlyIfChanged: Bool) {
        guard config.localIntentOnly else { return }
        resolveIntentLocked()
        let key = currentIntent.rawValue + "|" + firedSignals.sorted().joined(separator: ",")
        if onlyIfChanged, key == lastSnapshotKey { return }
        lastSnapshotKey = key
        enqueueLocked("intent_snapshot", data: snapshotLocked())
    }

    /// Signals that depend on elapsed time. Called on every tracked event and
    /// on each heartbeat, so dwell-time signals fire while the user stays put.
    private func evaluateSignalsLocked(at t: Date) {
        let screenType = ChaosScreen.classify(currentScreen)
        let tOn = timeOnScreenLocked(at: t)
        let sDur = sessionDurationLocked(at: t)
        let lastVisit = Int(storage.get(ChaosCore.lastVisitKey) ?? "0") ?? 0

        if visitCount <= 1 {
            fireSignalLocked("first_visit", meta: nil)
            fireSignalLocked("no_repeat", meta: nil)
        }
        if pagesViewed >= 2 { fireSignalLocked("pages_gte_2", meta: nil) }
        if sDur >= 60 && sDur <= 180 { fireSignalLocked("session_1_to_3_min", meta: nil) }
        if lastVisit > 0, t.timeIntervalSince1970 * 1000 - Double(lastVisit) < 86_400_000 {
            fireSignalLocked("repeat_within_day", meta: nil)
        }
        if screenType == .pricing, tOn > 30 { fireSignalLocked("pricing_over_30s", meta: nil) }
        if screenType == .caseStudy, tOn > 30 { fireSignalLocked("case_study_read", meta: nil) }
        if screenType == .feature, tOn > 60 { fireSignalLocked("feature_deepdive_over_1min", meta: nil) }
        if backgroundCount >= 2, totalBackground > ChaosCore.backgroundAbandonThreshold {
            fireSignalLocked("abandonment_risk", meta: [
                "background_count": backgroundCount,
                "total_background_ms": Int(totalBackground * 1000),
            ])
        }
    }

    /// `homepage_under_20s` means the user LEFT a home screen quickly, so it is
    /// decided when the screen is exited (or the app is backgrounded), not on view.
    private func fireHomeBounceIfNeededLocked(at t: Date) {
        guard ChaosScreen.classify(currentScreen) == .home,
              timeOnScreenLocked(at: t) < 20 else { return }
        fireSignalLocked("homepage_under_20s", meta: nil)
    }

    /// Timer tick. Internal so tests can drive it without waiting.
    func heartbeatTick() {
        locked {
            guard isRunnableLocked, !appInBackground else { return }
            let t = now()
            enqueueLocked("heartbeat", data: [
                "intent": .string(currentIntent.rawValue),
                "session_duration": .number(Double(sessionDurationLocked(at: t))),
                "pages_viewed": .number(Double(pagesViewed)),
            ])
            evaluateSignalsLocked(at: t)
            emitIntentSnapshotLocked(onlyIfChanged: true)
        }
    }

    // MARK: Session

    private static func resolveVisitorId(_ storage: ChaosStoring) -> String {
        if let id = storage.get(ChaosCore.visitorKey) { return id }
        let id = ChaosIDs.generateId()
        storage.set(ChaosCore.visitorKey, id)
        return id
    }

    private struct SessionInfo {
        var id: String
        var start: Date
        var isNew: Bool
        var previousExpired: Bool
        var previousId: String?
    }

    private func persistSessionLocked(id: String, start: Date, touchedAt: Date) {
        let obj: [String: Any] = [
            "id": id,
            "ts": touchedAt.timeIntervalSince1970 * 1000,
            "start": start.timeIntervalSince1970 * 1000,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) {
            storage.set(ChaosCore.sessionKey, s)
        }
    }

    private func resolveSessionLocked(at t: Date) -> SessionInfo {
        if let raw = storage.get(ChaosCore.sessionKey),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["id"] as? String,
           let ts = obj["ts"] as? Double,
           let start = obj["start"] as? Double {
            let age = t.timeIntervalSince1970 - ts / 1000
            if age < ChaosCore.sessionTTL {
                let startDate = Date(timeIntervalSince1970: start / 1000)
                persistSessionLocked(id: id, start: startDate, touchedAt: t)
                return SessionInfo(id: id, start: startDate, isNew: false,
                                   previousExpired: false, previousId: nil)
            }
            let freshId = ChaosIDs.generateId()
            persistSessionLocked(id: freshId, start: t, touchedAt: t)
            return SessionInfo(id: freshId, start: t, isNew: true,
                               previousExpired: true, previousId: id)
        }
        let id = ChaosIDs.generateId()
        persistSessionLocked(id: id, start: t, touchedAt: t)
        return SessionInfo(id: id, start: t, isNew: true, previousExpired: false, previousId: nil)
    }

    /// Close the current session and open a fresh one in place (used when the
    /// app returns to the foreground after the TTL elapsed).
    private func rotateSessionLocked(at t: Date, reason: String) {
        enqueueLocked("session_end", data: ["reason": .string(reason)])
        sessionId = ChaosIDs.generateId()
        sessionStart = t
        persistSessionLocked(id: sessionId, start: t, touchedAt: t)
        lastSessionTouchAt = t
        lastActivityAt = t
        firedSignals = []
        firedAt = [:]
        signalSequence = []
        currentIntent = .awareness
        stageHistory = [(stage: .awareness, at: t)]
        lastSnapshotKey = nil
        pagesViewed = 0
        storage.set(ChaosCore.pagesKey, "0")
        backgroundCount = 0
        totalBackground = 0
        screenEntryTime = t
        enqueueLocked("session_start", data: sessionStartPayloadLocked(isNew: true))
    }

    private func incrementVisitCountLocked(at t: Date) -> Int {
        let c = (Int(storage.get(ChaosCore.visitCountKey) ?? "0") ?? 0) + 1
        storage.set(ChaosCore.visitCountKey, String(c))
        storage.set(ChaosCore.lastVisitKey, String(Int(t.timeIntervalSince1970 * 1000)))
        return c
    }

    private func resolveAttributionLocked(_ initial: ChaosInitialAttribution?, at t: Date) -> [String: ChaosJSON] {
        if let raw = storage.get(ChaosCore.attributionKey),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj.mapValues { ChaosJSON.from($0) }
        }
        let landing = t.timeIntervalSince1970 * 1000
        var fresh: [String: ChaosJSON] = [
            "platform": .string("ios"),
            "landing_ts": .number(landing),
            "landing_hostname": .null,
        ]
        var plain: [String: Any] = ["platform": "ios", "landing_ts": landing]
        if let initial {
            if let utm = initial.utm {
                fresh["utm"] = .object(utm.mapValues { .string($0) })
                plain["utm"] = utm
            }
            if let ads = initial.adClicks {
                fresh["ad_clicks"] = .object(ads.mapValues { .string($0) })
                plain["ad_clicks"] = ads
            }
            if let r = initial.referrer {
                fresh["landing_referrer"] = .string(r)
                plain["landing_referrer"] = r
            }
            if let s = initial.screen {
                fresh["landing_pathname"] = .string(s)
                plain["landing_pathname"] = s
            }
            if let i = initial.installSource {
                fresh["install_source"] = .string(i)
                plain["install_source"] = i
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: plain),
           let s = String(data: d, encoding: .utf8) {
            storage.set(ChaosCore.attributionKey, s)
        }
        return fresh
    }

    private func loadIntentProfileLocked(at t: Date) -> [IntentStage: Double]? {
        guard let raw = storage.get(ChaosCore.intentProfileKey),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["at"] as? Double,
              let scores = obj["scores"] as? [String: Double] else { return nil }
        let age = t.timeIntervalSince1970 - at / 1000
        if age < 0 || age > ChaosCore.intentProfileMaxAge { return nil }
        let decay = pow(0.5, age / (24 * 60 * 60))
        var out: [IntentStage: Double] = [:]
        for (k, v) in scores {
            if let stage = IntentStage(rawValue: k) {
                out[stage] = v * decay
            }
        }
        return out
    }

    private func saveIntentProfileLocked(_ scores: [IntentStage: Double], at t: Date) {
        var plain: [String: Double] = [:]
        for (k, v) in scores { plain[k.rawValue] = v }
        let obj: [String: Any] = ["scores": plain, "at": t.timeIntervalSince1970 * 1000]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) {
            storage.set(ChaosCore.intentProfileKey, s)
        }
    }

    // MARK: Pending buffer

    private func loadPendingLocked() -> [ChaosEvent] {
        guard let raw = storage.get(ChaosCore.pendingBufferKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ChaosEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    private func savePendingLocked(_ events: [ChaosEvent]) {
        if let data = try? JSONEncoder().encode(events),
           let s = String(data: data, encoding: .utf8) {
            storage.set(ChaosCore.pendingBufferKey, s)
        }
    }

    /// Test hook: true once nothing is queued in memory and no flush is running.
    var isQuiescent: Bool {
        locked { queue.isEmpty && !isFlushing }
    }

    // MARK: Hashing

    /// SHA-256 hex of the UTF-8 value, unmodified — identical to the JS
    /// tracker's `sha256()` so hashed traits join across platforms.
    static func sha256Hex(_ value: String) -> String? {
#if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        return nil
#endif
    }

    // MARK: Timers

    private func startTimersLocked() {
        guard usesTimers else { return }
        cancelTimersLocked()

        let flush = DispatchSource.makeTimerSource(queue: timerQueue)
        flush.schedule(deadline: .now() + ChaosCore.flushInterval, repeating: ChaosCore.flushInterval)
        flush.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.runFlush(force: false) }
        }
        flush.resume()
        flushTimer = flush

        let heartbeat = DispatchSource.makeTimerSource(queue: timerQueue)
        heartbeat.schedule(deadline: .now() + ChaosCore.heartbeatInterval, repeating: ChaosCore.heartbeatInterval)
        heartbeat.setEventHandler { [weak self] in
            self?.heartbeatTick()
        }
        heartbeat.resume()
        heartbeatTimer = heartbeat
    }

    private func cancelTimersLocked() {
        flushTimer?.cancel()
        flushTimer = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: App lifecycle

    private func observeAppLifecycle() {
#if canImport(UIKit) && !os(watchOS)
        let shouldAdd: Bool = locked {
            if observing { return false }
            observing = true
            return true
        }
        guard shouldAdd else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
#endif
    }

#if canImport(UIKit) && !os(watchOS)
    @objc private func didEnterBackground() { handleDidEnterBackground() }
    @objc private func willEnterForeground() { handleWillEnterForeground() }
#endif

    /// Internal (not `private`) so tests can simulate lifecycle transitions.
    func handleDidEnterBackground() {
        let entered: Bool = locked {
            guard isRunnableLocked, !appInBackground else { return false }
            let t = now()
            appInBackground = true
            backgroundCount += 1
            lastBackgroundAt = t
            lastActivityAt = t
            enqueueLocked("app_background", data: [
                "background_count": .number(Double(backgroundCount)),
                "screen": currentScreen.map { .string($0) } ?? .null,
                "time_on_screen": .number(Double(timeOnScreenLocked(at: t))),
                "intent": .string(currentIntent.rawValue),
            ])
            fireHomeBounceIfNeededLocked(at: t)
            return true
        }
        // The OS may kill the process any time after this; don't wait for the timer.
        if entered { Task { await flush() } }
    }

    func handleWillEnterForeground() {
        locked {
            guard isRunnableLocked, appInBackground else { return }
            let t = now()
            appInBackground = false
            let idleFor = t.timeIntervalSince(lastActivityAt)
            if let since = lastBackgroundAt {
                totalBackground += t.timeIntervalSince(since)
            }
            lastBackgroundAt = nil
            enqueueLocked("app_foreground", data: [
                "background_count": .number(Double(backgroundCount)),
                "total_background_ms": .number(totalBackground * 1000),
            ])
            if idleFor > ChaosCore.sessionTTL {
                rotateSessionLocked(at: t, reason: "ttl_expired_on_resume")
            } else {
                touchLocked(at: t)
            }
        }
    }
}

// Convenience free function (JS parity).
@discardableResult
public func initChaosTracker(
    config: ChaosConfig,
    storage: ChaosStoring? = nil
) async -> ChaosTracker? {
    await ChaosTracker.shared.start(config: config, storage: storage)
}
