# ChaosKit

**Native iOS / Swift** port of Mathematica’s intent-aware analytics tracker  
([`p1-chaos-data`](https://github.com/mathematica-ai) / `p1-chaos-tracker` **native** adapter).

| Surface | Package |
|---------|---------|
| Web / RN / Node | `p1-chaos-tracker` (JS) |
| **iOS / SwiftUI / UIKit** | **ChaosKit** (this repo) |

Wire format matches `POST {apiBase}/ingest` (see p1-chaos-data `BACKEND_EVENT_SCHEMA.md`).

## Requirements

- iOS 15+ (also macOS 12+ for host tools/tests)
- Swift 5.9+
- Xcode 15+

## Install (Swift Package Manager)

### Xcode

**File → Add Package Dependencies…**

```
git@github.com-math:mathematica-ai/chaoskit.git
```

(or `https://github.com/mathematica-ai/chaoskit.git`)

### `Package.swift`

```swift
dependencies: [
  .package(url: "git@github.com-math:mathematica-ai/chaoskit.git", from: "0.1.0"),
],
targets: [
  .target(name: "YourApp", dependencies: ["ChaosKit"]),
]
```

## Quick start

```swift
import ChaosKit

// App launch (e.g. P1VisionApp.init or .task)
Task {
  _ = await initChaosTracker(config: ChaosConfig(
    siteId: "p1-vision",
    apiBase: "https://ap1.mathematica.ai/api/v1/intent",
    // Privacy-first: only compact intent_snapshot / identify leave the device
    localIntentOnly: true,
    initialAttribution: ChaosInitialAttribution(installSource: "app_store")
  ))
}

// Navigation
ChaosTracker.shared.trackScreen("Live")

// UI actions
ChaosTracker.shared.trackPress("shutter_photo")
ChaosTracker.shared.trackForm("lead", action: .start)

// Optional traits (PII dropped if hashIdentifiers without crypto polyfill)
ChaosTracker.shared.identify(["plan": "b2b_demo"])

// Force upload
Task { await ChaosTracker.shared.flush() }

// Kill switch
ChaosTracker.shared.optOut()
```

## Config

| Option | Default | Notes |
|--------|---------|--------|
| `siteId` | `nil` | App / product id on every event |
| `apiBase` | `https://ap1.mathematica.ai/api/v1/intent` | Must be absolute on device |
| `localIntentOnly` | `false` | **Recommended** for on-device photo apps — no raw click stream |
| `samplingRate` | `1` | Per-visitor 0…1 |
| `hasConsent` | `nil` | Return `false` to block init; `optOut()` always wins |
| `initialAttribution` | `nil` | UTM / install source at launch |

## Privacy

- Visitor / session ids are random `ct_…` values in `UserDefaults` (not IDFA).
- `localIntentOnly: true` sends only `intent_snapshot` (+ `identify`), not full behavioral streams.
- No photo or camera content is ever attached by this SDK.
- Pair with product privacy policy; for P1(vision) support contact **info@mathematica.ai**.

## Relation to p1-chaos-data

| Concern | JS native | ChaosKit |
|---------|-----------|----------|
| Storage | AsyncStorage | UserDefaults |
| App lifecycle | AppState | `UIApplication` notifications |
| Ingest | `fetch` → `/ingest` | `URLSession` → `/ingest` |
| Intent model | `core.js` | `Core.swift` (same stages / weights) |

## Develop

```bash
cd chaoskit
swift test
```

## License

MIT — Mathematiques Ltd.
