import Foundation

public struct ChaosInitialAttribution: Codable, Sendable, Equatable {
    public var utm: [String: String]?
    public var adClicks: [String: String]?
    public var referrer: String?
    public var screen: String?
    public var installSource: String?

    public init(
        utm: [String: String]? = nil,
        adClicks: [String: String]? = nil,
        referrer: String? = nil,
        screen: String? = nil,
        installSource: String? = nil
    ) {
        self.utm = utm
        self.adClicks = adClicks
        self.referrer = referrer
        self.screen = screen
        self.installSource = installSource
    }
}

public struct ChaosPrivacySignals: Sendable {
    /// Always false on iOS (browser GPC/DNT N/A).
    public var gpc: Bool
    public var dnt: Bool
    public var optedOut: Bool
}

public struct ChaosConfig: Sendable {
    public var siteId: String?
    /// Absolute base URL, e.g. `https://ap1.mathematica.ai/api/v1/intent`
    public var apiBase: String
    /// Optional write key — sent as `Authorization: Bearer …` on `/ingest`.
    public var apiKey: String?
    public var hasConsent: (@Sendable (ChaosPrivacySignals) -> Bool)?
    /// When true, `identify` traits named in `hashFields` are sent as the
    /// SHA-256 hex digest of the value (same scheme as the JS tracker) instead
    /// of plaintext.
    public var hashIdentifiers: Bool
    public var hashFields: [String]
    public var samplingRate: Double
    public var initialAttribution: ChaosInitialAttribution?
    public var userAgent: String?
    /// Resolve intent on-device; only emit `intent_snapshot` / `identify`.
    public var localIntentOnly: Bool
    /// Has no effect on native. The web tracker uses it to permit tracking on
    /// `localhost`; it exists here only so shared config code keeps compiling.
    @available(*, deprecated, message: "No effect on native; the option only applies to the web tracker.")
    public var allowLocalhost: Bool {
        get { _allowLocalhost }
        set { _allowLocalhost = newValue }
    }
    private var _allowLocalhost: Bool

    public init(
        siteId: String? = nil,
        apiBase: String = "https://ap1.mathematica.ai/api/v1/intent",
        apiKey: String? = nil,
        hasConsent: (@Sendable (ChaosPrivacySignals) -> Bool)? = nil,
        hashIdentifiers: Bool = false,
        hashFields: [String] = ["email", "name", "phone"],
        samplingRate: Double = 1,
        initialAttribution: ChaosInitialAttribution? = nil,
        userAgent: String? = nil,
        localIntentOnly: Bool = false,
        allowLocalhost: Bool = false
    ) {
        self.siteId = siteId
        self.apiBase = apiBase
        self.apiKey = apiKey
        self.hasConsent = hasConsent
        self.hashIdentifiers = hashIdentifiers
        self.hashFields = hashFields
        self.samplingRate = min(1, max(0, samplingRate))
        self.initialAttribution = initialAttribution
        self.userAgent = userAgent
        self.localIntentOnly = localIntentOnly
        self._allowLocalhost = allowLocalhost
    }
}

public enum ChaosFormAction: String, Sendable {
    case start, submit, abandon
}
