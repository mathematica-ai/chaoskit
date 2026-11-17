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
  .package(url: "git@github.com-math:mathematica-ai/chaoskit.git", from: "0.2.0"),
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

// Optional traits (with hashIdentifiers, fields in hashFields are sent as SHA-256 hex)
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
| `apiKey` | `nil` | Optional `Authorization: Bearer` on `/ingest` |
| `localIntentOnly` | `false` | **Recommended** for on-device photo apps — no raw click stream |
| `samplingRate` | `1` | Per-visitor 0…1 |
| `hasConsent` | `nil` | Return `false` to block init; `optOut()` always wins |
| `hashIdentifiers` | `false` | `identify` traits named in `hashFields` (`email`, `name`, `phone`) are sent as SHA-256 hex, same scheme as the JS tracker |
| `initialAttribution` | `nil` | UTM / install source at launch |

## Privacy

- Visitor / session ids are random `ct_…` values in `UserDefaults` (not IDFA).
- `localIntentOnly: true` sends only `intent_snapshot` (+ `identify`), not full behavioral streams.
- No photo or camera content is ever attached by this SDK.
- Ships a `PrivacyInfo.xcprivacy` (UserDefaults reason `CA92.1`; product-interaction analytics, not linked, no tracking).
- Pair with product privacy policy; for P1(vision) support contact **info@mathematica.ai**.

## Delivery and sessions

- Events are flushed every 5 s, on backgrounding, and on `flush()`.
- Anything being uploaded stays in a persisted buffer (max 100 events) until
  the server acknowledges it.
- Network errors, 5xx, 408 and 429 are retried with exponential backoff
  (5 s → 5 min) on the periodic timer; `flush()` and the background flush always
  try immediately. Other 4xx responses drop the batch (e.g. a bad `apiKey`).
- A session ends after 30 minutes without activity. Activity refreshes the
  stored session; returning to the foreground after the TTL closes the old
  session (`session_end`, reason `ttl_expired_on_resume`) and opens a new one.
- A 10 s heartbeat re-evaluates dwell-time signals. With `localIntentOnly` it
  sends an `intent_snapshot` only when the stage or fired signals changed.

## Thread safety

`ChaosTracker` can be called from any thread. All state is guarded by one
lock, and flushes are single-flight. A custom `ChaosStoring` must not call back
into the tracker from `get` / `set` / `remove`.

## Differences from the JS native adapter

- `session_end` for an expired session carries the **expired** session id (JS
  sends the new one).
- `homepage_under_20s` fires when Home is left within 20 s, not on view.
- Session rotation on resume is based on inactivity, not session age, and is
  followed by a `session_start`.
- Retry backoff and 4xx dropping (JS re-queues every failure).
- `allowLocalhost` has no effect; idle detection is not implemented.

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
swift test --sanitize=thread   # data-race check; also run in CI
```

## License

MIT — Mathematiques Ltd.
