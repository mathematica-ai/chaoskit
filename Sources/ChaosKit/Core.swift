import Foundation

// MARK: - Tunables (parity with p1-chaos-data/src/core.js)

public enum ChaosCore {
    public static let flushIntervalMs: TimeInterval = 5
    public static let heartbeatMs: TimeInterval = 10
    public static let idleTimeoutMs: TimeInterval = 30
    public static let maxBatchSize = 50
    public static let maxPendingBufferSize = 100
    public static let sessionTTLMs: TimeInterval = 30 * 60
    public static let intentHalfLifeMs: TimeInterval = 3 * 60
    public static let intentProfileMaxAgeMs: TimeInterval = 7 * 24 * 60 * 60
    public static let blurAbandonThresholdMs: TimeInterval = 45
    public static let engagedComponentsThreshold = 3

    public static let pendingBufferKey = "chaos_pending"
    public static let sessionKey = "chaos_session"
    public static let attributionKey = "chaos_attribution"
    public static let pagesKey = "chaos_pages_in_session"
    public static let visitorKey = "chaos_vid"
    public static let visitCountKey = "chaos_visit_count"
    public static let lastVisitKey = "chaos_last_visit"
    public static let optOutKey = "chaos_optout"
    public static let cartActiveKey = "chaos_cart_active"
    public static let intentProfileKey = "chaos_intent_profile"
}

// MARK: - Intent stages

public enum IntentStage: String, Codable, CaseIterable, Sendable {
    case awareness
    case interest
    case consideration
    case decision
    case evaluation

    public var weight: Double {
        switch self {
        case .awareness: 1
        case .interest: 2
        case .consideration: 3
        case .decision: 4
        case .evaluation: 5
        }
    }

    public var signals: [String] {
        switch self {
        case .awareness:
            ["first_visit", "homepage_under_20s", "blog_scroll_under_50", "no_repeat"]
        case .interest:
            ["pages_gte_2", "session_1_to_3_min", "content_download", "email_capture",
             "repeat_within_day", "component_engaged", "media_engaged"]
        case .consideration:
            ["pricing_over_30s", "comparison_click", "demo_form_start", "abandoned_cart",
             "faq_deep_scroll", "abandonment_risk", "form_abandon", "cta_hesitation", "copied_contact"]
        case .decision:
            ["trial_signup_attempt", "quote_request", "checkout_entered", "repeated_pricing_cart",
             "exit_intent_on_cta", "payment_reached", "copied_price"]
        case .evaluation:
            ["case_study_read", "roi_calc_use", "competitor_tab_switch",
             "feature_deepdive_over_1min", "media_completed"]
        }
    }
}

public enum ChaosCoreSignals {
    public static let signalWeights: [String: Double] = [
        "payment_reached": 10,
        "checkout_entered": 10,
        "repeated_pricing_cart": 9,
        "trial_signup_attempt": 9,
        "copied_price": 9,
        "quote_request": 8,
        "exit_intent_on_cta": 5,
        "copied_contact": 7,
        "demo_form_start": 6,
        "abandoned_cart": 6,
        "cta_hesitation": 4,
        "media_completed": 8,
        "roi_calc_use": 7,
        "competitor_tab_switch": 6,
        "media_engaged": 4,
    ]

    public static let negativeSignals: Set<String> = [
        "rage_click", "dead_click", "session_bounce", "form_error",
    ]
}

// MARK: - IDs & sampling

public enum ChaosIDs {
    public static func generateId() -> String {
        let t = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let r = String(UInt64.random(in: 0..<UInt64(1) << 40), radix: 36)
        return "ct_\(t)\(r)"
    }

    /// FNV-1a 32-bit — stable across runtimes for per-visitor sampling.
    public static func hashString(_ str: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for b in str.utf8 {
            h ^= UInt32(b)
            h = h &* 0x01000193
        }
        return h
    }

    public static func sampleBucket(_ visitorId: String) -> Double {
        Double(hashString(visitorId)) / Double(UInt32.max) // ~ / 2^32
    }

    public static func isSampledIn(visitorId: String, rate: Double) -> Bool {
        if rate >= 1 { return true }
        if rate <= 0 { return false }
        return sampleBucket(visitorId) < rate
    }
}

// MARK: - Screen classification

public enum ScreenType: String, Sendable {
    case pricing, checkout, demo, faq, caseStudy = "case_study"
    case blog, comparison, home, feature, other
}

public enum ChaosScreen {
    /// PascalCase → snake with leading slash (parity with native.js).
    public static func normalize(_ name: String) -> String {
        var out = "/"
        var prevLower = false
        for ch in name {
            if ch.isUppercase, prevLower {
                out.append("_")
            }
            out.append(ch.lowercased())
            prevLower = ch.isLowercase || ch.isNumber
        }
        return out.replacingOccurrences(of: " ", with: "_")
    }

    public static func classify(_ screen: String?) -> ScreenType {
        guard let screen, !screen.isEmpty else { return .other }
        let n = normalize(screen)
        let rules: [(ScreenType, NSRegularExpression)] = [
            (.pricing, try! NSRegularExpression(pattern: #"^\/(pricing|plans|packages)(_|$)"#)),
            (.checkout, try! NSRegularExpression(pattern: #"^\/(checkout|cart|payment|buy)(_|$)"#)),
            (.demo, try! NSRegularExpression(pattern: #"^\/(demo|trial|signup|register)(_|$)"#)),
            (.faq, try! NSRegularExpression(pattern: #"^\/(faq|help|support)(_|$)"#)),
            (.caseStudy, try! NSRegularExpression(pattern: #"^\/(case_stud|success_stor|customer)"#)),
            (.blog, try! NSRegularExpression(pattern: #"^\/(blog|article|post|news)(_|$)"#)),
            (.comparison, try! NSRegularExpression(pattern: #"^\/(compare|comparison|alternative)(_|$)"#)),
            (.home, try! NSRegularExpression(pattern: #"^\/(home|landing)(_|$)"#)),
            (.feature, try! NSRegularExpression(pattern: #"^\/(feature|product|solution)(_|$)"#)),
        ]
        let range = NSRange(n.startIndex..., in: n)
        for (type, re) in rules {
            if re.firstMatch(in: n, range: range) != nil { return type }
        }
        return .other
    }
}

// MARK: - Bot assessment

public struct BotAssessment: Codable, Sendable {
    public var flags: [String: Bool]
    public var score: Int
    public var isLikelyBot: Bool
    public var suppressInit: Bool

    enum CodingKeys: String, CodingKey {
        case flags, score
        case isLikelyBot = "is_likely_bot"
        case suppressInit = "suppress_init"
    }
}

public enum ChaosBot {
    private static let patterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\b(bot|crawler|spider|crawling)\b"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"headlesschrome|phantomjs|selenium|webdriver|puppeteer|playwright"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"curl\/|wget\/|python-requests"#, options: .caseInsensitive),
    ]

    public static func isBotUA(_ ua: String?) -> Bool {
        let s = ua ?? ""
        guard !s.isEmpty else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return patterns.contains { $0.firstMatch(in: s, range: range) != nil }
    }

    public static func assess(userAgent: String?) -> BotAssessment {
        var flags: [String: Bool] = [:]
        var score = 0
        if isBotUA(userAgent) {
            flags["bot_ua"] = true
            score += 100
        }
        if let ua = userAgent, ua.range(of: "headless", options: .caseInsensitive) != nil {
            flags["headless_ua"] = true
            score += 100
        }
        score = min(100, score)
        let likely = score >= 40
        return BotAssessment(
            flags: flags,
            score: score,
            isLikelyBot: likely,
            suppressInit: false
        )
    }
}

// MARK: - Intent resolution

public struct IntentResult: Sendable {
    public var stage: IntentStage
    public var score: Double
    public var scores: [IntentStage: Double]
    public var distribution: [IntentStage: Double]
    public var confidence: Double
    public var frustrated: Bool
}

public enum ChaosIntent {
    public static func resolve(
        firedSignals: Set<String>,
        firedAt: [String: Date] = [:],
        now: Date = Date(),
        halfLifeMs: TimeInterval = ChaosCore.intentHalfLifeMs,
        priorScores: [IntentStage: Double]? = nil
    ) -> IntentResult {
        var scores: [IntentStage: Double] = [:]
        for stage in IntentStage.allCases {
            scores[stage] = 0
        }

        let frustrated = !firedSignals.isDisjoint(with: ChaosCoreSignals.negativeSignals)

        for stage in IntentStage.allCases {
            for signal in stage.signals where firedSignals.contains(signal) {
                let base = ChaosCoreSignals.signalWeights[signal] ?? stage.weight
                var w = base
                if let t = firedAt[signal] {
                    let age = now.timeIntervalSince(t)
                    if halfLifeMs > 0 {
                        w *= pow(0.5, age / halfLifeMs)
                    }
                }
                scores[stage, default: 0] += w
            }
        }

        if let prior = priorScores {
            for (stage, v) in prior {
                scores[stage, default: 0] += v * 0.35
            }
        }

        // Always seed awareness lightly so empty sessions don't collapse.
        scores[.awareness, default: 0] += 0.25

        var best: IntentStage = .awareness
        var bestScore = scores[.awareness] ?? 0
        for stage in IntentStage.allCases {
            let s = scores[stage] ?? 0
            if s > bestScore {
                bestScore = s
                best = stage
            }
        }

        let total = scores.values.reduce(0, +)
        var dist: [IntentStage: Double] = [:]
        if total > 0 {
            for stage in IntentStage.allCases {
                dist[stage] = (scores[stage] ?? 0) / total
            }
        } else {
            for stage in IntentStage.allCases { dist[stage] = stage == .awareness ? 1 : 0 }
        }

        var confidence = dist[best] ?? 0
        if frustrated { confidence *= 0.6 }

        return IntentResult(
            stage: best,
            score: bestScore,
            scores: scores,
            distribution: dist,
            confidence: confidence,
            frustrated: frustrated
        )
    }
}
