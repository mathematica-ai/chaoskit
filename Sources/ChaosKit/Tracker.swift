import Foundation
#if canImport(UIKit)
import UIKit
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
public final class ChaosTracker: @unchecked Sendable {
    public static let shared = ChaosTracker()

    private let lock = NSLock()
    private var storage: ChaosStoring = ChaosUserDefaultsStorage()
    private var config = ChaosConfig()
    private var active = false
    private var stopped = false

    private var visitorId = ""
    private var sessionId = ""
    private var sessionStart = Date()
    private var siteId: String?
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
    private var flushTimer: Timer?
    private var heartbeatTimer: Timer?
    private var isFlushing = false
    private var backgroundCount = 0
    private var totalBackgroundMs: TimeInterval = 0
    private var lastBackgroundAt: Date?
    private var appInBackground = false

    private let localAllowed: Set<String> = ["intent_snapshot", "identify"]

    private init() {}

    // MARK: Lifecycle

    /// Start (or return) the shared tracker. Returns `nil` when consent/sampling rejects.
    @discardableResult
    public func start(config: ChaosConfig, storage customStorage: ChaosStoring? = nil) async -> ChaosTracker? {
        // NSLock is fine for Swift 5; avoid async-context lock warnings by
        // doing the active check without holding the lock across awaits.
        if active && !stopped { return self }

        if let customStorage { self.storage = customStorage }
        self.config = config

        let signals = privacySignals()
        if signals.optedOut { return nil }
        if let consent = config.hasConsent, !consent(signals) { return nil }

        let vid = resolveVisitorId()
        if !ChaosIDs.isSampledIn(visitorId: vid, rate: config.samplingRate) {
            return nil
        }

        visitorId = vid
        siteId = config.siteId
        let session = resolveSession()
        sessionId = session.id
        sessionStart = session.start
        visitCount = incrementVisitCount()
        pagesViewed = Int(self.storage.get(ChaosCore.pagesKey) ?? "0") ?? 0
        priorIntentScores = loadIntentProfile()
        attribution = resolveAttribution(config.initialAttribution)
        stageHistory = [(stage: .awareness, at: sessionStart)]
        currentIntent = .awareness
        firedSignals = []
        firedAt = [:]
        signalSequence = []
        queue = []
        stopped = false
        active = true

        var device: [String: ChaosJSON] = [
            "platform": .string("ios"),
            "bot_assessment": .object([
                "flags": .object(ChaosBot.assess(userAgent: config.userAgent).flags.mapValues { .bool($0) }),
                "score": .number(Double(ChaosBot.assess(userAgent: config.userAgent).score)),
                "is_likely_bot": .bool(ChaosBot.assess(userAgent: config.userAgent).isLikelyBot),
            ]),
        ]
        if let ua = config.userAgent {
            device["user_agent"] = .string(ua)
        }
#if canImport(UIKit)
        device["model"] = .string(UIDevice.current.model)
        device["system_version"] = .string(UIDevice.current.systemVersion)
#endif

        enqueue("session_start", data: [
            "visit_count": .number(Double(visitCount)),
            "is_new_session": .bool(session.isNew),
            "device": .object(device),
            "attribution": .object(attribution),
            "storage_persistent": .bool(self.storage.isPersistent),
        ])

        if session.previousExpired {
            enqueue("session_end", data: ["reason": .string("ttl_expired")])
        }

        startTimers()
        observeAppLifecycle()
        Task { await flush() }
        return self
    }

    public func destroy() {
        lock.lock()
        flushTimer?.invalidate(); flushTimer = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        active = false
        stopped = true
        queue.removeAll()
        lock.unlock()
#if canImport(UIKit)
        NotificationCenter.default.removeObserver(self)
#endif
    }

    public func optOut() {
        storage.set(ChaosCore.optOutKey, "1")
        lock.lock()
        stopped = true
        queue.removeAll()
        lock.unlock()
        storage.remove(ChaosCore.pendingBufferKey)
    }

    public func optIn() {
        storage.remove(ChaosCore.optOutKey)
        lock.lock()
        stopped = false
        lock.unlock()
    }

    // MARK: Tracking API

    public func trackScreen(_ name: String, params: [String: Any]? = nil) {
        guard isRunnable else { return }
        lock.lock()
        if let prev = currentScreen {
            let secs = Int(Date().timeIntervalSince(screenEntryTime))
            lock.unlock()
            enqueue("screen_exit", data: [
                "screen": .string(prev),
                "time_on_screen": .number(Double(secs)),
            ])
            lock.lock()
        }
        currentScreen = name
        screenEntryTime = Date()
        pagesViewed += 1
        storage.set(ChaosCore.pagesKey, String(pagesViewed))
        let pages = pagesViewed
        let attr = attribution
        lock.unlock()

        touch()
        enqueue("screen_view", data: [
            "screen": .string(name),
            "screen_type": .string(ChaosScreen.classify(name).rawValue),
            "pages_viewed": .number(Double(pages)),
            "params": ChaosJSON.from(params),
            "attribution": .object(attr),
        ])
        evaluateSignals()
        emitIntentSnapshotIfNeeded()
    }

    public func trackPress(_ name: String, meta: [String: Any]? = nil) {
        guard isRunnable else { return }
        touch()
        enqueue("press", data: [
            "track": .string(name),
            "screen_type": .string(ChaosScreen.classify(currentScreen).rawValue),
            "meta": ChaosJSON.from(meta),
        ])
        if name.lowercased().contains("pricing") || name.lowercased().contains("compare") {
            fireSignal("comparison_click")
        }
        if name.lowercased().contains("checkout") || name.lowercased().contains("buy") {
            fireSignal("checkout_entered")
        }
        evaluateSignals()
        emitIntentSnapshotIfNeeded()
    }

    public func trackForm(_ name: String, action: ChaosFormAction, type: String? = nil) {
        guard isRunnable else { return }
        touch()
        enqueue("form", data: [
            "name": .string(name),
            "action": .string(action.rawValue),
            "form_type": .string(type ?? "unknown"),
        ])
        switch action {
        case .start: fireSignal("demo_form_start")
        case .abandon: fireSignal("form_abandon")
        case .submit: break
        }
        evaluateSignals()
        emitIntentSnapshotIfNeeded()
    }

    public func track(type: String, data: [String: Any]? = nil) {
        guard isRunnable else { return }
        touch()
        var payload: [String: ChaosJSON] = [:]
        if let data {
            for (k, v) in data { payload[k] = ChaosJSON.from(v) }
        }
        enqueue(type, data: payload)
    }

    public func identify(_ traits: [String: String]) {
        guard isRunnable else { return }
        var out: [String: ChaosJSON] = [:]
        for (k, v) in traits {
            if config.hashIdentifiers, config.hashFields.contains(k) {
                // Fail closed without CryptoKit dependency: drop PII fields.
                continue
            }
            out[k] = .string(v)
        }
        enqueue("identify", data: ["traits": .object(out)])
    }

    public func fireSignal(_ signal: String, meta: [String: Any]? = nil) {
        guard isRunnable else { return }
        lock.lock()
        if firedSignals.contains(signal) {
            lock.unlock()
            return
        }
        firedSignals.insert(signal)
        firedAt[signal] = Date()
        signalSequence.append((s: signal, t: Date()))
        lock.unlock()

        let stage = resolveIntent()
        enqueue("signal", data: [
            "signal": .string(signal),
            "intent_stage": .string(stage.rawValue),
            "screen_type": .string(ChaosScreen.classify(currentScreen).rawValue),
            "time_on_screen": .number(Double(timeOnScreen)),
            "session_duration": .number(Double(sessionDuration)),
            "pages_viewed": .number(Double(pagesViewed)),
            "attribution": .object(attribution),
            "meta": ChaosJSON.from(meta),
        ])
    }

    public var intent: IntentStage {
        lock.lock(); defer { lock.unlock() }
        return currentIntent
    }

    public var intentSnapshot: [String: ChaosJSON] {
        resolveIntent()
        lock.lock()
        defer { lock.unlock() }
        let entered = stageHistory.last?.at ?? sessionStart
        return [
            "stage": .string(currentIntent.rawValue),
            "score": .number(lastIntent.score),
            "confidence": .number(lastIntent.confidence),
            "frustrated": .bool(lastIntent.frustrated),
            "session_duration": .number(Double(sessionDuration)),
            "pages_viewed": .number(Double(pagesViewed)),
            "screen": currentScreen.map { .string($0) } ?? .null,
            "time_to_current_stage_ms": .number(max(0, entered.timeIntervalSince(sessionStart) * 1000)),
            "signal_sequence": .array(signalSequence.map { .string($0.s) }),
            "signals_fired": .array(Array(firedSignals).map { .string($0) }),
        ]
    }

    // MARK: Flush

    public func flush() async {
        if isFlushing || stopped { return }
        isFlushing = true
        let pending = loadPending()
        if !pending.isEmpty {
            clearPending()
            queue = pending + queue
        }
        var batches: [[ChaosEvent]] = []
        while !queue.isEmpty {
            let n = min(ChaosCore.maxBatchSize, queue.count)
            batches.append(Array(queue.prefix(n)))
            queue.removeFirst(n)
        }
        let base = config.apiBase
        let key = config.apiKey
        let intent = currentIntent.rawValue
        let vid = visitorId
        let sid = sessionId
        let site = siteId

        for batch in batches {
            do {
                try await sendBatch(
                    batch,
                    apiBase: base,
                    apiKey: key,
                    intent: intent,
                    visitorId: vid,
                    sessionId: sid,
                    siteId: site
                )
            } catch {
                var p = loadPending()
                p.append(contentsOf: batch)
                if p.count > ChaosCore.maxPendingBufferSize {
                    p = Array(p.suffix(ChaosCore.maxPendingBufferSize))
                }
                savePending(p)
            }
        }

        isFlushing = false
    }

    // MARK: - Internals

    private var isRunnable: Bool {
        lock.lock(); defer { lock.unlock() }
        return active && !stopped
    }

    private var timeOnScreen: Int {
        Int(Date().timeIntervalSince(screenEntryTime))
    }

    private var sessionDuration: Int {
        Int(Date().timeIntervalSince(sessionStart))
    }

    private func privacySignals() -> ChaosPrivacySignals {
        ChaosPrivacySignals(
            gpc: false,
            dnt: false,
            optedOut: storage.get(ChaosCore.optOutKey) == "1"
        )
    }

    private func touch() {
        // idle hooks reserved for future
    }

    private func enqueue(_ type: String, data: [String: ChaosJSON]) {
        lock.lock()
        defer { lock.unlock() }
        guard active, !stopped else { return }
        if config.localIntentOnly, !localAllowed.contains(type) { return }
#if canImport(UIKit)
        let ver = UIDevice.current.systemVersion
#else
        let ver: String? = nil
#endif
        let event = ChaosEvent(
            eventId: ChaosIDs.generateId(),
            type: type,
            ts: Int64(Date().timeIntervalSince1970 * 1000),
            visitorId: visitorId,
            sessionId: sessionId,
            siteId: siteId,
            platform: "ios",
            platformVersion: ver,
            screen: currentScreen,
            data: data
        )
        queue.append(event)
    }

    @discardableResult
    private func resolveIntent() -> IntentStage {
        lock.lock()
        let result = ChaosIntent.resolve(
            firedSignals: firedSignals,
            firedAt: firedAt,
            priorScores: priorIntentScores
        )
        lastIntent = result
        if result.stage != currentIntent {
            currentIntent = result.stage
            stageHistory.append((stage: currentIntent, at: Date()))
        }
        let stage = currentIntent
        let scores = result.scores
        lock.unlock()
        saveIntentProfile(scores)
        return stage
    }

    private func emitIntentSnapshotIfNeeded() {
        guard config.localIntentOnly else { return }
        let snap = intentSnapshot
        enqueue("intent_snapshot", data: snap)
    }

    private func evaluateSignals() {
        let screenType = ChaosScreen.classify(currentScreen)
        let tOn = timeOnScreen
        let sDur = sessionDuration
        let lastVisit = Int(storage.get(ChaosCore.lastVisitKey) ?? "0") ?? 0
        let visits = visitCount

        if visits <= 1 {
            fireSignal("first_visit")
            fireSignal("no_repeat")
        }
        if pagesViewed >= 2 { fireSignal("pages_gte_2") }
        if sDur >= 60 && sDur <= 180 { fireSignal("session_1_to_3_min") }
        if lastVisit > 0, Date().timeIntervalSince1970 * 1000 - Double(lastVisit) < 86_400_000 {
            fireSignal("repeat_within_day")
        }
        if screenType == .pricing, tOn > 30 { fireSignal("pricing_over_30s") }
        if screenType == .home, tOn < 20 { fireSignal("homepage_under_20s") }
        if screenType == .caseStudy, tOn > 30 { fireSignal("case_study_read") }
        if screenType == .feature, tOn > 60 { fireSignal("feature_deepdive_over_1min") }
        if backgroundCount >= 2, totalBackgroundMs > ChaosCore.blurAbandonThresholdMs {
            fireSignal("abandonment_risk", meta: [
                "background_count": backgroundCount,
                "total_background_ms": Int(totalBackgroundMs * 1000),
            ])
        }
    }

    private func resolveVisitorId() -> String {
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
    }

    private func resolveSession() -> SessionInfo {
        if let raw = storage.get(ChaosCore.sessionKey),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["id"] as? String,
           let ts = obj["ts"] as? Double,
           let start = obj["start"] as? Double {
            let age = Date().timeIntervalSince1970 - ts / 1000
            if age < ChaosCore.sessionTTLMs {
                let now = Date().timeIntervalSince1970 * 1000
                let updated: [String: Any] = ["id": id, "ts": now, "start": start]
                if let d = try? JSONSerialization.data(withJSONObject: updated),
                   let s = String(data: d, encoding: .utf8) {
                    storage.set(ChaosCore.sessionKey, s)
                }
                return SessionInfo(id: id, start: Date(timeIntervalSince1970: start / 1000),
                                   isNew: false, previousExpired: false)
            }
            let freshId = ChaosIDs.generateId()
            let now = Date().timeIntervalSince1970 * 1000
            let fresh: [String: Any] = ["id": freshId, "ts": now, "start": now]
            if let d = try? JSONSerialization.data(withJSONObject: fresh),
               let s = String(data: d, encoding: .utf8) {
                storage.set(ChaosCore.sessionKey, s)
            }
            return SessionInfo(id: freshId, start: Date(), isNew: true, previousExpired: true)
        }
        let id = ChaosIDs.generateId()
        let now = Date().timeIntervalSince1970 * 1000
        let created: [String: Any] = ["id": id, "ts": now, "start": now]
        if let d = try? JSONSerialization.data(withJSONObject: created),
           let s = String(data: d, encoding: .utf8) {
            storage.set(ChaosCore.sessionKey, s)
        }
        return SessionInfo(id: id, start: Date(), isNew: true, previousExpired: false)
    }

    private func incrementVisitCount() -> Int {
        let c = (Int(storage.get(ChaosCore.visitCountKey) ?? "0") ?? 0) + 1
        storage.set(ChaosCore.visitCountKey, String(c))
        storage.set(ChaosCore.lastVisitKey, String(Int(Date().timeIntervalSince1970 * 1000)))
        return c
    }

    private func resolveAttribution(_ initial: ChaosInitialAttribution?) -> [String: ChaosJSON] {
        if let raw = storage.get(ChaosCore.attributionKey),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj.mapValues { ChaosJSON.from($0) }
        }
        var fresh: [String: ChaosJSON] = [
            "platform": .string("ios"),
            "landing_ts": .number(Date().timeIntervalSince1970 * 1000),
            "landing_hostname": .null,
        ]
        if let initial {
            if let utm = initial.utm {
                fresh["utm"] = .object(utm.mapValues { .string($0) })
            }
            if let ads = initial.adClicks {
                fresh["ad_clicks"] = .object(ads.mapValues { .string($0) })
            }
            if let r = initial.referrer { fresh["landing_referrer"] = .string(r) }
            if let s = initial.screen { fresh["landing_pathname"] = .string(s) }
            if let i = initial.installSource { fresh["install_source"] = .string(i) }
        }
        // Persist
        var plain: [String: Any] = ["platform": "ios", "landing_ts": Date().timeIntervalSince1970 * 1000]
        if let initial {
            if let utm = initial.utm { plain["utm"] = utm }
            if let ads = initial.adClicks { plain["ad_clicks"] = ads }
            if let r = initial.referrer { plain["landing_referrer"] = r }
            if let s = initial.screen { plain["landing_pathname"] = s }
            if let i = initial.installSource { plain["install_source"] = i }
        }
        if let d = try? JSONSerialization.data(withJSONObject: plain),
           let s = String(data: d, encoding: .utf8) {
            storage.set(ChaosCore.attributionKey, s)
        }
        return fresh
    }

    private func loadIntentProfile() -> [IntentStage: Double]? {
        guard let raw = storage.get(ChaosCore.intentProfileKey),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["at"] as? Double,
              let scores = obj["scores"] as? [String: Double] else { return nil }
        let age = Date().timeIntervalSince1970 - at / 1000
        if age < 0 || age > ChaosCore.intentProfileMaxAgeMs { return nil }
        let decay = pow(0.5, age / (24 * 60 * 60))
        var out: [IntentStage: Double] = [:]
        for (k, v) in scores {
            if let stage = IntentStage(rawValue: k) {
                out[stage] = v * decay
            }
        }
        return out
    }

    private func saveIntentProfile(_ scores: [IntentStage: Double]) {
        var plain: [String: Double] = [:]
        for (k, v) in scores { plain[k.rawValue] = v }
        let obj: [String: Any] = ["scores": plain, "at": Date().timeIntervalSince1970 * 1000]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) {
            storage.set(ChaosCore.intentProfileKey, s)
        }
    }

    private func loadPending() -> [ChaosEvent] {
        guard let raw = storage.get(ChaosCore.pendingBufferKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ChaosEvent].self, from: data) else {
            return []
        }
        return decoded
    }

    private func savePending(_ events: [ChaosEvent]) {
        if let data = try? JSONEncoder().encode(events),
           let s = String(data: data, encoding: .utf8) {
            storage.set(ChaosCore.pendingBufferKey, s)
        }
    }

    private func clearPending() {
        storage.remove(ChaosCore.pendingBufferKey)
    }

    private func sendBatch(
        _ batch: [ChaosEvent],
        apiBase: String,
        apiKey: String?,
        intent: String,
        visitorId: String,
        sessionId: String,
        siteId: String?
    ) async throws {
        var base = apiBase
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/ingest") else {
            throw URLError(.badURL)
        }
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
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(
            Body(batch: batch, intent: intent, visitor_id: visitorId,
                 session_id: sessionId, site_id: siteId)
        )
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func startTimers() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushTimer?.invalidate()
            self.heartbeatTimer?.invalidate()
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: ChaosCore.flushIntervalMs, repeats: true) { [weak self] _ in
                Task { await self?.flush() }
            }
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: ChaosCore.heartbeatMs, repeats: true) { [weak self] _ in
                guard let self, self.isRunnable else { return }
                self.enqueue("heartbeat", data: [
                    "intent": .string(self.currentIntent.rawValue),
                    "session_duration": .number(Double(self.sessionDuration)),
                    "pages_viewed": .number(Double(self.pagesViewed)),
                ])
            }
        }
    }

    private func observeAppLifecycle() {
#if canImport(UIKit)
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

#if canImport(UIKit)
    @objc private func didEnterBackground() {
        guard isRunnable else { return }
        lock.lock()
        if !appInBackground {
            appInBackground = true
            backgroundCount += 1
            lastBackgroundAt = Date()
            let bc = backgroundCount
            let screen = currentScreen
            let t = timeOnScreen
            let intent = currentIntent.rawValue
            lock.unlock()
            enqueue("app_background", data: [
                "background_count": .number(Double(bc)),
                "screen": screen.map { .string($0) } ?? .null,
                "time_on_screen": .number(Double(t)),
                "intent": .string(intent),
            ])
            Task { await flush() }
        } else {
            lock.unlock()
        }
    }

    @objc private func willEnterForeground() {
        guard isRunnable else { return }
        lock.lock()
        if appInBackground {
            appInBackground = false
            if let t = lastBackgroundAt {
                totalBackgroundMs += Date().timeIntervalSince(t)
            }
            lastBackgroundAt = nil
            lock.unlock()
            enqueue("app_foreground", data: [
                "background_count": .number(Double(backgroundCount)),
                "total_background_ms": .number(totalBackgroundMs * 1000),
            ])
        } else {
            lock.unlock()
        }
    }
#endif
}

// Convenience free function (JS parity).
@discardableResult
public func initChaosTracker(
    config: ChaosConfig,
    storage: ChaosStoring? = nil
) async -> ChaosTracker? {
    await ChaosTracker.shared.start(config: config, storage: storage)
}
