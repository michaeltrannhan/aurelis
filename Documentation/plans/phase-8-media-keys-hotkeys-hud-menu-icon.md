# Phase 8 Media Keys, Hotkeys, HUD, And Menu Bar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add system-feeling controls outside the popup: media keys, global hotkeys, HUD, and menu bar icon state.

**Architecture:** Add native macOS control services with no third-party package dependency. Media keys use `CGEvent` tap and Accessibility permission. App hotkeys use Carbon `RegisterEventHotKey`. Target selection chooses the audible app first, then frontmost app, then selected/pinned app. HUD and menu icon consume pure value models so behavior is testable without AppKit windows.

**Tech Stack:** Swift 6, AppKit, CoreGraphics event taps, Carbon hotkeys, SwiftUI HUD view, XCTest.

---

## Reference Notes

FineTune uses:

- `NSSystemDefined.data1` decoding for F10/F11/F12 media keys
- Accessibility trust for media-key interception
- watchdog handling for disabled event taps
- volume-up auto-unmute
- repeat handling for volume keys
- HUD that hides automatically
- menu bar icon state derived from volume, mute, and current device

Phase 8 controls Auralis app volume, not hardware device volume. Device hardware volume enhancements stay Phase 12.

## File Structure

- Create `Sources/Auralis/Controls/AccessibilityPermissionService.swift`: Accessibility trust query and System Settings opener.
- Create `Sources/Auralis/Controls/MediaKeyEventDecoder.swift`: pure media-key decoder.
- Create `Sources/Auralis/Controls/MediaKeyMonitor.swift`: CGEvent tap lifecycle and watchdog.
- Create `Sources/Auralis/Controls/ShortcutAction.swift`: hotkey action model.
- Create `Sources/Auralis/Controls/GlobalHotkeyRegistrar.swift`: Carbon hotkey registration.
- Create `Sources/Auralis/Controls/AppControlTargetResolver.swift`: audible/frontmost target selection.
- Create `Sources/Auralis/Controls/AppControlCommandExecutor.swift`: apply volume and mute commands to `AudioControlStore`.
- Create `Sources/Auralis/Views/HUD/VolumeHUDState.swift`: pure HUD value model.
- Create `Sources/Auralis/Views/HUD/VolumeHUDView.swift`: SwiftUI HUD content.
- Create `Sources/Auralis/Views/HUD/VolumeHUDWindowController.swift`: AppKit panel and hide timer.
- Create `Sources/Auralis/Views/MenuBar/MenuBarIconState.swift`: pure menu icon model.
- Modify `Sources/Auralis/AuralisApp.swift`: own long-lived monitors/controllers and dynamic menu icon.
- Modify `Sources/Auralis/Views/Settings/ShortcutsSettingsTab.swift`: media-key and hotkey settings.
- Modify `Sources/Auralis/Domain/AppCustomization.swift`: control settings.
- Test `Tests/AuralisTests/MediaKeyEventDecoderTests.swift`.
- Test `Tests/AuralisTests/AppControlTargetResolverTests.swift`.
- Test `Tests/AuralisTests/AppControlCommandExecutorTests.swift`.
- Test `Tests/AuralisTests/MenuBarIconStateTests.swift`.
- Test `Tests/AuralisTests/VolumeHUDStateTests.swift`.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Control Settings

**Files:**
- Modify: `Sources/Auralis/Domain/AppCustomization.swift`
- Test: `Tests/AuralisTests/CustomizationTests.swift`

- [ ] **Step 1: Write settings defaults test**

Add:

```swift
func testControlSettingsDefaultToEnabledSafeValues() {
    let customization = AppCustomization()

    XCTAssertTrue(customization.mediaKeysEnabled)
    XCTAssertTrue(customization.hotkeysEnabled)
    XCTAssertEqual(customization.hudStyle, .compact)
    XCTAssertEqual(customization.menuBarIconStyle, .speaker)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testControlSettingsDefaultToEnabledSafeValues
```

Expected: compile failure for missing settings.

- [ ] **Step 3: Add control enums and fields**

Add:

```swift
enum HUDStyle: String, CaseIterable, Codable, Identifiable {
    case compact
    case classic
    var id: String { rawValue }
}

enum MenuBarIconStyle: String, CaseIterable, Codable, Identifiable {
    case speaker
    case equalizer
    case waveform
    var id: String { rawValue }
}
```

Add to `AppCustomization`:

```swift
var mediaKeysEnabled: Bool
var hotkeysEnabled: Bool
var hudStyle: HUDStyle
var menuBarIconStyle: MenuBarIconStyle
```

Decode missing values as `true`, `true`, `.compact`, and `.speaker`.

- [ ] **Step 4: Run settings tests**

Run:

```sh
swift test --filter CustomizationTests/testControlSettingsDefaultToEnabledSafeValues
```

Expected: PASS.

## Task 2: Media Key Decoder

**Files:**
- Create: `Sources/Auralis/Controls/MediaKeyEventDecoder.swift`
- Test: `Tests/AuralisTests/MediaKeyEventDecoderTests.swift`

- [ ] **Step 1: Write decoder tests**

Create:

```swift
import XCTest
@testable import Auralis

final class MediaKeyEventDecoderTests: XCTestCase {
    func testDecodesVolumeUpDownAndMute() {
        let decoder = IOKitMediaKeyDecoder()

        XCTAssertEqual(decoder.decode(data1: Self.data1(keyType: 0, keyFlags: 0x0A00)), .volumeUp(isRepeat: false))
        XCTAssertEqual(decoder.decode(data1: Self.data1(keyType: 1, keyFlags: 0x0A01)), .volumeDown(isRepeat: true))
        XCTAssertEqual(decoder.decode(data1: Self.data1(keyType: 7, keyFlags: 0x0A00)), .muteToggle)
    }

    func testIgnoresKeyUpAndUnknownKeys() {
        let decoder = IOKitMediaKeyDecoder()

        XCTAssertNil(decoder.decode(data1: Self.data1(keyType: 0, keyFlags: 0x0B00)))
        XCTAssertNil(decoder.decode(data1: Self.data1(keyType: 99, keyFlags: 0x0A00)))
        XCTAssertNil(decoder.decode(data1: Self.data1(keyType: 7, keyFlags: 0x0A01)))
    }

    private static func data1(keyType: Int, keyFlags: Int) -> Int {
        (keyType << 16) | keyFlags
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter MediaKeyEventDecoderTests
```

Expected: compile failure for missing decoder.

- [ ] **Step 3: Implement decoder**

Create:

```swift
enum MediaKeyEvent: Equatable {
    case volumeUp(isRepeat: Bool)
    case volumeDown(isRepeat: Bool)
    case muteToggle
}

protocol MediaKeyEventDecoding {
    func decode(data1: Int) -> MediaKeyEvent?
}

struct IOKitMediaKeyDecoder: MediaKeyEventDecoding {
    func decode(data1: Int) -> MediaKeyEvent? {
        let keyType = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0xFF) != 0

        guard isDown else { return nil }

        switch keyType {
        case 0: return .volumeUp(isRepeat: isRepeat)
        case 1: return .volumeDown(isRepeat: isRepeat)
        case 7: return isRepeat ? nil : .muteToggle
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run decoder tests**

Run:

```sh
swift test --filter MediaKeyEventDecoderTests
```

Expected: PASS.

## Task 3: Target Resolver

**Files:**
- Create: `Sources/Auralis/Controls/AppControlTargetResolver.swift`
- Test: `Tests/AuralisTests/AppControlTargetResolverTests.swift`

- [ ] **Step 1: Write resolver tests**

Create:

```swift
import XCTest
@testable import Auralis

final class AppControlTargetResolverTests: XCTestCase {
    func testAudibleAppWinsOverFrontmost() {
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let rows = [
            DisplayableAppRow(identity: music, displayName: "Music", isActive: true, isPinned: false, level: 0.4, settings: AppAudioSettings(displayName: "Music", volume: 0.8)),
            DisplayableAppRow(identity: safari, displayName: "Safari", isActive: true, isPinned: false, level: 0.1, settings: AppAudioSettings(displayName: "Safari", volume: 0.8))
        ]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, frontmostBundleID: safari.rawValue, selectedAppID: nil), music)
    }

    func testFrontmostWinsWhenNoAudibleApp() {
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")
        let rows = [
            DisplayableAppRow(identity: safari, displayName: "Safari", isActive: true, isPinned: false, level: 0.01, settings: AppAudioSettings(displayName: "Safari", volume: 0.8))
        ]

        XCTAssertEqual(AppControlTargetResolver.resolve(rows: rows, frontmostBundleID: safari.rawValue, selectedAppID: nil), safari)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AppControlTargetResolverTests
```

Expected: compile failure for missing resolver.

- [ ] **Step 3: Implement resolver**

Create:

```swift
enum AppControlTargetResolver {
    static let audibleThreshold = 0.05

    static func resolve(
        rows: [DisplayableAppRow],
        frontmostBundleID: String?,
        selectedAppID: AudioAppIdentity?
    ) -> AudioAppIdentity? {
        if let audible = rows.filter({ $0.level >= audibleThreshold }).max(by: { $0.level < $1.level }) {
            return audible.identity
        }
        if let frontmostBundleID,
           let row = rows.first(where: { $0.identity.rawValue == frontmostBundleID || $0.settings.displayName == frontmostBundleID }) {
            return row.identity
        }
        if let selectedAppID, rows.contains(where: { $0.identity == selectedAppID }) {
            return selectedAppID
        }
        return rows.first(where: \.isPinned)?.identity ?? rows.first?.identity
    }
}
```

- [ ] **Step 4: Run resolver tests**

Run:

```sh
swift test --filter AppControlTargetResolverTests
```

Expected: PASS.

## Task 4: Command Executor

**Files:**
- Create: `Sources/Auralis/Controls/AppControlCommandExecutor.swift`
- Test: `Tests/AuralisTests/AppControlCommandExecutorTests.swift`

- [ ] **Step 1: Write pure command tests**

Create tests for command math:

```swift
import XCTest
@testable import Auralis

final class AppControlCommandExecutorTests: XCTestCase {
    func testVolumeUpAutoUnmutes() {
        let result = AppControlCommandExecutor.nextSettings(
            settings: AppAudioSettings(displayName: "Music", volume: 0.5, isMuted: true),
            action: .volumeUp,
            step: 0.05
        )

        XCTAssertEqual(result.volume, 0.55, accuracy: 0.0001)
        XCTAssertFalse(result.isMuted)
    }

    func testVolumeDownClampsAtZeroAndMutes() {
        let result = AppControlCommandExecutor.nextSettings(
            settings: AppAudioSettings(displayName: "Music", volume: 0.02, isMuted: false),
            action: .volumeDown,
            step: 0.05
        )

        XCTAssertEqual(result.volume, 0, accuracy: 0.0001)
        XCTAssertTrue(result.isMuted)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AppControlCommandExecutorTests
```

Expected: compile failure for missing executor.

- [ ] **Step 3: Implement command math**

Create:

```swift
enum AppControlAction {
    case volumeUp
    case volumeDown
    case muteToggle
}

enum AppControlCommandExecutor {
    static func nextSettings(settings: AppAudioSettings, action: AppControlAction, step: Double) -> AppAudioSettings {
        var next = settings
        switch action {
        case .volumeUp:
            next.setVolume(next.volume + step)
            next.isMuted = false
        case .volumeDown:
            next.setVolume(next.volume - step)
            if next.volume <= 0.001 {
                next.isMuted = true
            }
        case .muteToggle:
            next.isMuted.toggle()
        }
        return next
    }
}
```

Add an instance executor that resolves target identity and calls `AudioControlStore.setVolume` and `setMuted`.

- [ ] **Step 4: Run command tests**

Run:

```sh
swift test --filter AppControlCommandExecutorTests
```

Expected: PASS.

## Task 5: Media Key Monitor And Accessibility

**Files:**
- Create: `Sources/Auralis/Controls/AccessibilityPermissionService.swift`
- Create: `Sources/Auralis/Controls/MediaKeyMonitor.swift`
- Modify: `Sources/Auralis/Views/Settings/ShortcutsSettingsTab.swift`
- Test: `Tests/AuralisTests/MediaKeyEventDecoderTests.swift`

- [ ] **Step 1: Implement Accessibility service**

Add:

```swift
final class AccessibilityPermissionService: ObservableObject {
    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }
}
```

- [ ] **Step 2: Implement monitor lifecycle**

`MediaKeyMonitor` owns:

- decoder
- CGEvent tap
- run-loop source
- disabled-watchdog state
- command executor
- HUD presenter

Install with:

```swift
CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << 14),
    callback: mediaKeyTapCallback,
    userInfo: Unmanaged.passUnretained(self).toOpaque()
)
```

Process only `NSEvent.EventType.systemDefined` subtype `8`. Swallow decoded media-key events when media keys are enabled and Accessibility is trusted.

- [ ] **Step 3: Add watchdog behavior**

When callback receives `.tapDisabledByTimeout` or `.tapDisabledByUserInput`:

1. refresh Accessibility trust
2. stop monitor when trust is revoked
3. re-enable once when trust remains
4. mark `MediaKeyStatus.isOffline = true` on a second disable inside 5 seconds

- [ ] **Step 4: Add settings UI**

Shortcuts tab shows:

- media keys enabled toggle
- Accessibility permission row
- retry button when media keys are offline
- volume step picker

- [ ] **Step 5: Run build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 6: Global Hotkeys

**Files:**
- Create: `Sources/Auralis/Controls/ShortcutAction.swift`
- Create: `Sources/Auralis/Controls/GlobalHotkeyRegistrar.swift`
- Modify: `Sources/Auralis/Views/Settings/ShortcutsSettingsTab.swift`
- Test: `Tests/AuralisTests/CustomizationTests.swift`

- [ ] **Step 1: Write shortcut action test**

Add:

```swift
func testShortcutActionsHaveDefaultBindings() {
    XCTAssertEqual(ShortcutAction.allCases.map(\.label), ["Toggle Popup", "Volume Up", "Volume Down", "Mute"])
    XCTAssertEqual(ShortcutAction.targetAppVolumeUp.defaultBinding.keyCode, 126)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testShortcutActionsHaveDefaultBindings
```

Expected: compile failure for missing shortcut model.

- [ ] **Step 3: Implement shortcut models**

Create:

```swift
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePopup
    case targetAppVolumeUp
    case targetAppVolumeDown
    case targetAppMuteToggle

    var id: String { rawValue }
}
```

Default bindings:

- toggle popup: Option+Command+Space
- volume up: Option+Command+Up
- volume down: Option+Command+Down
- mute: Option+Command+M

- [ ] **Step 4: Implement Carbon registrar**

Use `RegisterEventHotKey`, `UnregisterEventHotKey`, and an app event handler. Map each registered hotkey ID back to `ShortcutAction`, then call command executor or toggle the menu-bar popup.

- [ ] **Step 5: Run shortcut tests and build**

Run:

```sh
swift test --filter CustomizationTests/testShortcutActionsHaveDefaultBindings
swift build
```

Expected: PASS and build succeeds.

## Task 7: HUD And Menu Bar Icon

**Files:**
- Create: `Sources/Auralis/Views/HUD/VolumeHUDState.swift`
- Create: `Sources/Auralis/Views/HUD/VolumeHUDView.swift`
- Create: `Sources/Auralis/Views/HUD/VolumeHUDWindowController.swift`
- Create: `Sources/Auralis/Views/MenuBar/MenuBarIconState.swift`
- Modify: `Sources/Auralis/AuralisApp.swift`
- Test: `Tests/AuralisTests/VolumeHUDStateTests.swift`
- Test: `Tests/AuralisTests/MenuBarIconStateTests.swift`

- [ ] **Step 1: Write value-model tests**

Add:

```swift
func testMenuBarIconVolumeBuckets() {
    XCTAssertEqual(VolumeBucket.bucket(for: 0), .zero)
    XCTAssertEqual(VolumeBucket.bucket(for: 0.2), .low)
    XCTAssertEqual(VolumeBucket.bucket(for: 0.5), .mid)
    XCTAssertEqual(VolumeBucket.bucket(for: 0.9), .high)
}

func testHUDStateClampsVolume() {
    let state = VolumeHUDState(appName: "Music", volume: 2, isMuted: false)

    XCTAssertEqual(state.volume, 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
swift test --filter MenuBarIconStateTests
swift test --filter VolumeHUDStateTests
```

Expected: compile failure for missing models.

- [ ] **Step 3: Implement menu icon state**

Add `VolumeBucket`, `MenuBarIconImage`, and `MenuBarIconState` value models. Speaker style maps mute to `speaker.slash.fill`; non-muted volume maps buckets to `speaker.fill`, `speaker.wave.1.fill`, `speaker.wave.2.fill`, or `speaker.wave.3.fill`.

- [ ] **Step 4: Implement HUD**

`VolumeHUDState` includes:

```swift
var appName: String
var volume: Double
var isMuted: Bool
```

Clamp volume to the closed unit range. `VolumeHUDWindowController` hosts `VolumeHUDView` in an `NSPanel`, positions it near top right, and hides after 900 milliseconds.

- [ ] **Step 5: Wire app root**

`AuralisApp` owns:

- `AccessibilityPermissionService`
- `MediaKeyStatus`
- `MediaKeyMonitor`
- `GlobalHotkeyRegistrar`
- `VolumeHUDWindowController`

Use dynamic `MenuBarExtra` image state from `MenuBarIconState`.

- [ ] **Step 6: Run tests and build**

Run:

```sh
swift test --filter MenuBarIconStateTests
swift test --filter VolumeHUDStateTests
swift build
```

Expected: PASS and build succeeds.

## Task 8: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- Accessibility permission requirement for media keys
- target resolution order
- volume-up auto-unmute behavior
- global hotkey defaults
- HUD hide timing
- menu icon state rules

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter MediaKeyEventDecoderTests
swift test --filter AppControlTargetResolverTests
swift test --filter AppControlCommandExecutorTests
swift test --filter MenuBarIconStateTests
swift test --filter VolumeHUDStateTests
swift test --filter CustomizationTests
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

- [ ] **Step 4: Manual control test**

Run:

```sh
open .build/Auralis.app
```

Manual checks:

- Grant Accessibility permission.
- Press volume up/down media keys while an app plays audio.
- Confirm target app volume changes.
- Confirm volume-up unmutes muted target.
- Confirm mute key toggles target mute.
- Confirm HUD appears and hides.
- Confirm popup-visible state suppresses HUD.
- Confirm Option+Command+Up/Down/M affect target app.
- Confirm Option+Command+Space toggles popup.
- Confirm menu bar icon updates for mute and volume buckets.

## Review Notes

Phase 8 adds process-wide controls. Keep device hardware volume, DDC, input devices, and loudness outside this phase.
