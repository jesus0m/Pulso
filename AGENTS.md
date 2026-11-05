# Pulso agent guide

These instructions apply to this repository. Read `README.md` for current
features, connection limitations, build requirements, and licensing.

## Project map

Pulso is a native SwiftUI quota dashboard for Codex, Claude, and GitHub Copilot.
It has no separate application backend or third-party package dependencies.

- `App/`: iPhone UI, authentication sessions, app state, background refresh,
  notifications, Live Activity control, and phone-to-watch synchronization.
- `Core/`: shared models, provider clients and parsers, Keychain access, quota
  timelines, and widget refresh intents. Files have explicit target membership.
- `Widgets/`: iPhone widgets, StandBy layouts, and Live Activity presentation.
- `Watch/` and `WatchWidgets/`: companion watch app and complications.
- `Tests/`, `UITests/`, and `WatchUITests/`: XCTest suites.
- `App/Localizable.xcstrings`: Spanish and English resources shared by all four
  shipped targets. `App/Assets.xcassets` contains the app icon and provider logos.

The promotional website is a separate repository; app changes do not require
website edits or deployments unless requested.

## Project generation and signing

- Use macOS with Xcode 27.2 and Python 3, matching the documented toolchain.
  Deployment targets are iOS 17 and watchOS 10. Newer widget APIs require the
  newer SDK even when protected by runtime availability checks.
- `scripts/generate_project.py` is the authoritative project generator. It
  writes the Xcode project, shared schemes, shipped Info.plists, and entitlements.
  Make persistent configuration, version, or membership changes there and
  regenerate; do not fix generated files alone.
- The generator discovers Swift files directly inside the existing source
  folders, not recursively. Update discovery and target membership when needed,
  especially for shared Core files used by widgets or watch targets.
- Preserve existing local signing settings. Do not hardcode a personal signing
  team or change bundle IDs, App Groups, or Keychain groups to bypass failures.
  Device builds require the developer's own consistent signing configuration.

Run commands from the repository root:

```bash
python3 scripts/generate_project.py
open Pulso.xcodeproj
```

Inspect regenerated diffs for unintended signing or configuration changes.
Do not introduce a Swift Package workflow: this is an Xcode app project.

## Verification

Use the existing XCTest suites and keep changes focused. Start with the relevant
tests; run the full unit suite for changes affecting shared behavior or multiple
targets. Add focused regressions for behavior changes, not documentation alone.

The commands below mirror `.github/workflows/ios-ci.yml`. Choose an installed
iPhone simulator if its name differs. Keep `-testLanguage es -testRegion ES`:
existing assertions depend on Spanish localization.

```bash
xcodebuild -project Pulso.xcodeproj -scheme Pulso \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=latest' \
  -testLanguage es -testRegion ES \
  -parallel-testing-enabled NO \
  -only-testing:PulsoTests test
```

For changes to demo gating, launch arguments, or Release configuration, also run:

```bash
xcodebuild -project Pulso.xcodeproj -scheme Pulso \
  -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=latest' \
  -testLanguage es -testRegion ES \
  -parallel-testing-enabled NO \
  -only-testing:PulsoUITests/DashboardTests/testReleaseBuildIgnoresDemoAndResetArguments \
  ENABLE_TESTABILITY=YES test
```

- Keep normal simulator signing enabled. Do not use `CODE_SIGNING_ALLOWED=NO`:
  App Group and shared Keychain tests depend on simulated entitlements.
- `ENABLE_TESTABILITY=YES` above is a command-only override because the scheme
  also builds unit tests with `@testable`; do not enable it globally for Release.
- CI uses the official `xcode-27` runner and pinned actions. Preserve its minimal
  permissions; do not change runners or bypass assertions to hide toolchain,
  locale, or entitlement failures.
- Documentation-only edits need no app build or simulator test run. Review the
  actual diff and report what was checked; never imply unrun tests passed.

## Behavior and safety invariants

- Preserve Spanish and English localization using existing SwiftUI localization
  and `String(localized:)` patterns. Update the string catalog for both languages.
  Reuse existing provider styling, assets, and accessibility identifiers.
- Preserve actor isolation, extension-safe APIs, and platform availability checks
  when changing shared code; not every Core file belongs in every target.
- Missing usage or allowance data is unknown, not zero consumption or a full
  quota. Keep reading timestamps and stale states truthful. A countdown is not
  evidence of a fresh provider response.
- Widget refresh uses `RefreshQuotaIntent` without foregrounding the app.
  iOS controls automatic refresh scheduling; do not promise polling intervals.
- Keep credentials in the existing Keychain path, with restricted shared access
  for the app and widget after first unlock. Preserve legacy migration behavior.
  The watch receives quota state, not provider credentials.
- Never log, commit, or publish real tokens, cookies, account data, signing keys,
  provisioning profiles, or screenshots containing private information. Use
  synthetic fixtures and simulator captures for tests and public assets.
- Demo controls, sample data, and reset launch arguments must remain Debug-only;
  Release must ignore `--demo` and `--reset-preferences`. Never run demo/reset
  tests on a real device with connected accounts. Use simulators by default;
  any physical-device validation requires explicit authorization and must not
  reset accounts or preferences.
- Provider endpoints and authenticated web sessions can change or be restricted.
  Respect provider policies and surface failures honestly rather than inventing
  usage values or bypassing authentication challenges.

## Scope and distribution

Make surgical changes, preserve unrelated local edits, and avoid new dependencies
or tooling without a demonstrated need. Do not modify real account sessions to
make tests pass.

Pulso uses the custom personal, noncommercial source-available `LICENSE`; it is
not MIT-licensed or an OSI open-source project. Preserve third-party notices.
A GitHub source release is not App Store approval or a universally installable
IPA. Do not publish binaries, change licensing, or create releases unless asked.
