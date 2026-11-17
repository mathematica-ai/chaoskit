import Foundation

/// ChaosKit — native iOS / Swift port of Mathematica **p1-chaos-tracker** (native adapter).
///
/// Intent-aware, privacy-conscious product analytics for SwiftUI and UIKit apps.
/// Wire protocol compatible with `POST {apiBase}/ingest` used by web and RN trackers.
///
/// Related JS package: `p1-chaos-data` / `p1-chaos-tracker`.
///
/// ```swift
/// import ChaosKit
///
/// Task {
///   _ = await initChaosTracker(config: ChaosConfig(
///     siteId: "p1-vision",
///     apiBase: "https://ap1.mathematica.ai/api/v1/intent",
///     localIntentOnly: true
///   ))
///   ChaosTracker.shared.trackScreen("Live")
/// }
/// ```
public enum ChaosKitModule {
    public static let version = "0.2.0"

    /// The bundled privacy manifest (UserDefaults required-reason declaration).
    static var privacyManifestURL: URL? {
        Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }
}
