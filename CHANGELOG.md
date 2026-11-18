# Changelog

## [0.2.0] - 2026-11-18

### Fixed
- **Thread safety.** All tracker state is now guarded by one lock; `flush()`,
  `start()`, the heartbeat and signal evaluation no longer read or write state
  unsynchronised. Flushes are single-flight.
- `UIDevice.current` is read once on the main actor in `start()`; tracking
  calls from background threads no longer touch UIKit.
- `session_end` for an expired session is sent with the **expired** session's
  id and before the new `session_start` (it used to carry the new id).
- Dwell-time signals (`pricing_over_30s`, `case_study_read`,
  `feature_deepdive_over_1min`, `session_1_to_3_min`) are evaluated on every
  heartbeat, so they fire while the user stays on a screen.
- `homepage_under_20s` fires when a home screen is **left** (or the app is
  backgrounded) within 20 s, instead of on every home view.
- Events being uploaded stay in the pending buffer until the server
  acknowledges them, so a process kill mid-flush does not lose them.
- The stored session timestamp is refreshed on activity (at most every 30 s),
  and the session rotates when the app returns to the foreground after 30
  minutes of inactivity (`session_end` reason `ttl_expired_on_resume`, then a
  new `session_start`).
- Timers no longer depend on the main run loop and are cancelled reliably by
  `destroy()`.

### Changed
- **Retry policy.** Failed flushes back off exponentially (5 s, 10 s, 20 s …
  capped at 5 min) for the periodic timer; explicit `flush()` calls and the
  background flush still try immediately. Batches rejected with a 4xx other
  than 408/429 are dropped instead of being retried forever.
- **`hashIdentifiers` now hashes.** Traits named in `hashFields` are sent as
  SHA-256 hex (same scheme as the JS tracker). Previously they were dropped.
- In `localIntentOnly` mode a heartbeat sends an `intent_snapshot` only when
  the stage or the set of fired signals changed.
- `signals_fired` in snapshots is sorted.
- `abandoned_cart` fires at start when the `chaos_cart_active` flag is set
  (JS parity).
- `ChaosScreen.classify` compiles its patterns once.

### Added
- `PrivacyInfo.xcprivacy` (UserDefaults reason `CA92.1`; product-interaction
  analytics, not linked, not used for tracking).
- Correctly named duration constants on `ChaosCore` (`flushInterval`,
  `heartbeatInterval`, `sessionTTL`, `intentHalfLife`, …), all in seconds.
- CI (`swift build`, `swift test`, thread sanitizer) and a tag/version guard.

### Deprecated
- `ChaosCore.…Ms` constants — they always held seconds. Use the new names.
- `ChaosConfig.allowLocalhost` — it has no effect on native.

## [0.1.1]

- Fix Swift 6 concurrency error on `UIDevice` access; assess the bot once.
- Optional `apiKey` Bearer auth on `/ingest`.

## [0.1.0]

- Initial ChaosKit: native iOS/Swift port of `p1-chaos-tracker`.
