# Phase 13 Device Inspector, Automation, And Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish release-quality support features: device inspector, URL automation, signing/notarization, and update path.

**Architecture:** Add inspector as an expandable device detail model, URL automation as a small parser/executor over existing store commands, and distribution scripts/configuration as reproducible release tooling. Keep release configuration separate from debug build scripts.

**Tech Stack:** Swift 6, CoreAudio inspector properties, AppKit URL handling, shell release scripts, Sparkle-compatible update path, XCTest.

---

## Reference Notes

FineTune's final polish includes device inspector rows for transport, sample rate, physical format, UID, hog-mode owner, sample-rate picker, URL automation commands, app delegate URL handling, and Sparkle update management.

Phase 13 does not add new realtime DSP. It packages and exposes the work already completed.

## File Structure

- Create `Sources/EQMacRep/Audio/Devices/DeviceInspectorInfo.swift`.
- Create `Sources/EQMacRep/Audio/Devices/DeviceInspectorService.swift`.
- Create `Sources/EQMacRep/Views/DeviceInspectorView.swift`.
- Create `Sources/EQMacRep/Automation/URLAutomationCommand.swift`.
- Create `Sources/EQMacRep/Automation/URLAutomationParser.swift`.
- Create `Sources/EQMacRep/Automation/URLAutomationExecutor.swift`.
- Modify `Sources/EQMacRep/EQMacRepApp.swift`: app delegate URL routing.
- Modify `Sources/EQMacRep/Views/Settings/UpdatesSettingsTab.swift`: update status and check button.
- Create `Sources/EQMacRep/Updates/UpdateManager.swift`.
- Create `Scripts/package-release.sh`.
- Create `Scripts/notarize-release.sh`.
- Create `Documentation/release-checklist.md`.
- Test `Tests/EQMacRepTests/DeviceInspectorInfoTests.swift`.
- Test `Tests/EQMacRepTests/URLAutomationParserTests.swift`.
- Test `Tests/EQMacRepTests/URLAutomationExecutorTests.swift`.
- Test `Tests/EQMacRepTests/ReleaseConfigurationTests.swift`.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Device Inspector Info

**Files:**
- Create: `Sources/EQMacRep/Audio/Devices/DeviceInspectorInfo.swift`
- Test: `Tests/EQMacRepTests/DeviceInspectorInfoTests.swift`

- [ ] **Step 1: Write formatter tests**

Create:

```swift
import CoreAudio
import XCTest
@testable import EQMacRep

final class DeviceInspectorInfoTests: XCTestCase {
    func testFormatsSampleRates() {
        XCTAssertEqual(DeviceInspectorInfo.formatSampleRate(48000), "48 kHz")
        XCTAssertEqual(DeviceInspectorInfo.formatSampleRate(44100), "44.1 kHz")
        XCTAssertEqual(DeviceInspectorInfo.formatSampleRate(0), "-")
    }

    func testInfoGridIncludesSampleRatePickerWhenSettable() {
        let info = DeviceInspectorInfo(
            transportLabel: "USB",
            sampleRate: 48000,
            availableSampleRates: [44100, 48000],
            sampleRateSettable: true,
            formatLabel: "24-bit PCM",
            hogModeOwner: -1,
            uid: "usb"
        )

        XCTAssertTrue(DeviceInspectorLayout(info: info).rows.contains(.sampleRate(display: "48 kHz", isPicker: true, options: [44100, 48000])))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter DeviceInspectorInfoTests
```

Expected: compile failure for missing inspector model.

- [ ] **Step 3: Implement info and layout**

Add:

```swift
struct DeviceInspectorInfo: Equatable {
    var transportLabel: String
    var sampleRate: Double
    var availableSampleRates: [Double]
    var sampleRateSettable: Bool
    var formatLabel: String?
    var hogModeOwner: pid_t
    var uid: String
}
```

Add formatters for sample rate, physical format, and hog-mode owner. Add `DeviceInspectorLayout` pure row builder.

- [ ] **Step 4: Run info tests**

Run:

```sh
swift test --filter DeviceInspectorInfoTests
```

Expected: PASS.

## Task 2: Inspector Service And View

**Files:**
- Create: `Sources/EQMacRep/Audio/Devices/DeviceInspectorService.swift`
- Create: `Sources/EQMacRep/Views/DeviceInspectorView.swift`
- Modify: `Sources/EQMacRep/Views/MenuBarRootView.swift`
- Test: `Tests/EQMacRepTests/DeviceInspectorInfoTests.swift`

- [ ] **Step 1: Implement CoreAudio operations**

Service reads:

- transport type
- nominal sample rate
- available nominal sample rates
- physical stream format
- hog-mode owner PID
- UID

Service writes:

- nominal sample rate when `AudioObjectIsPropertySettable` returns true

- [ ] **Step 2: Add listeners**

Register listeners for:

- `kAudioDevicePropertyNominalSampleRate`
- `kAudioDevicePropertyHogMode`

Remove listeners on collapse and tolerate `kAudioHardwareBadObjectError`.

- [ ] **Step 3: Add inspector UI**

Output device rows get an expand button. Expanded inspector shows:

- transport
- sample rate or sample-rate picker
- physical format
- device UID with copy button
- hog-mode owner message
- transient error for rejected sample-rate write

- [ ] **Step 4: Run build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 3: URL Automation Parser

**Files:**
- Create: `Sources/EQMacRep/Automation/URLAutomationCommand.swift`
- Create: `Sources/EQMacRep/Automation/URLAutomationParser.swift`
- Test: `Tests/EQMacRepTests/URLAutomationParserTests.swift`

- [ ] **Step 1: Write parser tests**

Create:

```swift
import XCTest
@testable import EQMacRep

final class URLAutomationParserTests: XCTestCase {
    func testParsesSetVolume() throws {
        let url = URL(string: "eqmacrep://set-volume?app=com.example.Music&volume=25")!

        XCTAssertEqual(URLAutomationParser.parse(url), .setVolume(app: "com.example.Music", volume: 0.25))
    }

    func testRejectsWrongScheme() {
        let url = URL(string: "other://set-volume?app=a&volume=50")!

        XCTAssertNil(URLAutomationParser.parse(url))
    }
}
```

- [ ] **Step 2: Run parser test to verify it fails**

Run:

```sh
swift test --filter URLAutomationParserTests
```

Expected: compile failure for missing parser.

- [ ] **Step 3: Implement command model**

Add:

```swift
enum URLAutomationCommand: Equatable {
    case setVolume(app: String, volume: Double)
    case stepVolume(app: String, direction: VolumeStepDirection)
    case setMute(app: String, muted: Bool)
    case toggleMute(app: String)
    case setRoute(app: String, route: DeviceRoute)
    case reset(app: String?)
}
```

Parser supports:

- `eqmacrep://set-volume?app=<id>&volume=0..100`
- `eqmacrep://step-volume?app=<id>&direction=up|down`
- `eqmacrep://set-mute?app=<id>&muted=true|false`
- `eqmacrep://toggle-mute?app=<id>`
- `eqmacrep://set-route?app=<id>&device=<uid>|follow-default`
- `eqmacrep://reset`
- `eqmacrep://reset?app=<id>`

- [ ] **Step 4: Run parser tests**

Run:

```sh
swift test --filter URLAutomationParserTests
```

Expected: PASS.

## Task 4: URL Automation Executor

**Files:**
- Create: `Sources/EQMacRep/Automation/URLAutomationExecutor.swift`
- Modify: `Sources/EQMacRep/EQMacRepApp.swift`
- Test: `Tests/EQMacRepTests/URLAutomationExecutorTests.swift`

- [ ] **Step 1: Write executor tests**

Create:

```swift
import XCTest
@testable import EQMacRep

@MainActor
final class URLAutomationExecutorTests: XCTestCase {
    func testSetVolumeCreatesSettingsForInactiveApp() throws {
        let backend = MockAudioBackend(apps: [])
        let store = try AudioControlStore(settingsStore: SettingsStore(settingsURL: uniqueSettingsURL()), backend: backend)
        let executor = URLAutomationExecutor(store: store)

        try executor.execute(.setVolume(app: "com.example.Music", volume: 0.25))

        XCTAssertEqual(store.settings.appSettings[AudioAppIdentity(rawValue: "com.example.Music")]?.volume, 0.25)
    }
}
```

- [ ] **Step 2: Run executor test to verify it fails**

Run:

```sh
swift test --filter URLAutomationExecutorTests
```

Expected: compile failure for missing executor.

- [ ] **Step 3: Implement executor**

Executor maps string app IDs to `AudioAppIdentity(rawValue:)`, calls existing store methods, creates settings for inactive apps, and forwards backend commands through the store.

- [ ] **Step 4: Add app delegate URL handling**

Add `NSApplicationDelegateAdaptor` to `EQMacRepApp`. In:

```swift
application(_:open:)
```

parse each URL and execute commands on the main actor.

- [ ] **Step 5: Run executor tests**

Run:

```sh
swift test --filter URLAutomationExecutorTests
swift build
```

Expected: PASS and build succeeds.

## Task 5: Update Path

**Files:**
- Create: `Sources/EQMacRep/Updates/UpdateManager.swift`
- Modify: `Package.swift`
- Modify: `Sources/EQMacRep/Views/Settings/UpdatesSettingsTab.swift`
- Test: `Tests/EQMacRepTests/ReleaseConfigurationTests.swift`

- [ ] **Step 1: Write update settings test**

Add:

```swift
func testUpdateSettingsDefaultToManualChecksAvailable() {
    let settings = UpdateSettings()

    XCTAssertFalse(settings.automaticallyChecksForUpdates)
    XCTAssertNil(settings.lastCheckDate)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter ReleaseConfigurationTests/testUpdateSettingsDefaultToManualChecksAvailable
```

Expected: compile failure for missing update settings.

- [ ] **Step 3: Add update manager abstraction**

Create:

```swift
struct UpdateSettings: Codable, Equatable {
    var automaticallyChecksForUpdates: Bool = false
    var lastCheckDate: Date?
}

protocol UpdateManaging: ObservableObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}
```

Add a Sparkle-backed implementation for release builds and a no-op implementation for debug builds. Add the Sparkle SPM dependency in `Package.swift` during this phase.

- [ ] **Step 4: Wire Updates tab**

Updates tab shows app version, auto-check toggle, last check date, and Check Now button.

- [ ] **Step 5: Run update tests and build**

Run:

```sh
swift test --filter ReleaseConfigurationTests/testUpdateSettingsDefaultToManualChecksAvailable
swift build
```

Expected: PASS and build succeeds.

## Task 6: Release Scripts And Entitlements

**Files:**
- Create: `Scripts/package-release.sh`
- Create: `Scripts/notarize-release.sh`
- Create: `Documentation/release-checklist.md`
- Modify: package/app metadata files required by current build system
- Test: `Tests/EQMacRepTests/ReleaseConfigurationTests.swift`

- [ ] **Step 1: Write release file tests**

Add:

```swift
func testReleaseScriptsExist() {
    XCTAssertTrue(FileManager.default.fileExists(atPath: "Scripts/package-release.sh"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: "Scripts/notarize-release.sh"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: "Documentation/release-checklist.md"))
}
```

- [ ] **Step 2: Create scripts**

`Scripts/package-release.sh`:

- clean release build
- build app bundle
- codesign app with Developer ID Application identity from environment
- create zip or dmg artifact

`Scripts/notarize-release.sh`:

- submit artifact with `xcrun notarytool`
- wait for result
- staple notarization ticket
- verify Gatekeeper assessment

- [ ] **Step 3: Create checklist**

`Documentation/release-checklist.md` includes:

- version bump
- tests
- manual audio smoke test
- orphan aggregate cleanup verification
- signing identity
- notarization
- update feed
- rollback plan

- [ ] **Step 4: Run release checks**

Run:

```sh
swift test --filter ReleaseConfigurationTests
swift build
```

Expected: PASS and build succeeds.

## Task 7: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- device inspector properties
- sample-rate write behavior
- URL automation scheme and commands
- release scripts
- signing/notarization requirements
- update path

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter DeviceInspectorInfoTests
swift test --filter URLAutomationParserTests
swift test --filter URLAutomationExecutorTests
swift test --filter ReleaseConfigurationTests
```

Expected: PASS.

- [ ] **Step 3: Run full suite and build**

Run:

```sh
swift test
swift build
Scripts/build-debug-app.sh
```

Expected: tests pass, build succeeds, debug app bundle exists.

- [ ] **Step 4: Manual release-quality test**

Run:

```sh
open .build/EQMacRep.app
```

Manual checks:

- Expand device inspector and verify transport, sample rate, format, UID, and hog mode.
- Change sample rate on a supported device and confirm UI refreshes.
- Run `open 'eqmacrep://set-volume?app=com.example.Music&volume=25'` and confirm persisted volume.
- Run mute, route, and reset automation URLs.
- Build release artifact.
- Sign and notarize release artifact in a release environment.
- Launch notarized artifact on a clean macOS account.

## Review Notes

Phase 13 is the final release-readiness phase. Do not change DSP or routing behavior except where inspector or automation calls existing public command surfaces.
