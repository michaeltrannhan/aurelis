# Phase 1 Permissions And Safety Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add permission-state detection, safe denied/missing states, and a development app bundle path before process taps are attempted.

**Architecture:** Add a small permission domain model and injectable permission client. `AudioControlStore` owns published permission state; CoreAudio tap phases will read that state before creating taps. A debug `.app` wrapper supplies `NSAudioCaptureUsageDescription`; full signing/notarization remains Phase 13.

**Tech Stack:** Swift 6, SwiftUI, CoreGraphics screen-capture permission APIs, Bundle metadata, XCTest, shell script for debug app bundle.

---

## Reference Notes

Apple's Core Audio tap documentation requires `NSAudioCaptureUsageDescription` in `Info.plist` for audio capture via taps. CoreGraphics also exposes `CGPreflightScreenCaptureAccess()` and `CGRequestScreenCaptureAccess()` for Screen Recording permission state. Phase 1 must surface missing bundle metadata before any tap work begins.

## File Structure

- Create `Sources/Auralis/Permissions/AudioCapturePermission.swift`: domain enums and user-facing copy.
- Create `Sources/Auralis/Permissions/AudioCapturePermissionClient.swift`: protocol and system implementation.
- Modify `Sources/Auralis/State/AudioControlStore.swift`: inject permission client, publish permission state, refresh/request methods.
- Modify `Sources/Auralis/Views/MenuBarRootView.swift`: show permission banner.
- Modify `Sources/Auralis/Views/SettingsView.swift`: show permission state and action.
- Create `Resources/Auralis-Info.plist`: debug app-bundle plist with usage description.
- Create `Scripts/build-debug-app.sh`: build and wrap SwiftPM executable in `.build/Auralis.app`.
- Create `Tests/AuralisTests/AudioCapturePermissionTests.swift`: pure permission-state tests.
- Modify `Tests/AuralisTests/AudioControlStoreTests.swift`: store permission mapping tests.
- Update `Documentation/flows.md`, `Documentation/phase-tracker.md`, and `README.md`.

## Task 1: Permission Domain Model

**Files:**
- Create: `Sources/Auralis/Permissions/AudioCapturePermission.swift`
- Test: `Tests/AuralisTests/AudioCapturePermissionTests.swift`

- [ ] **Step 1: Write failing tests**

Create `AudioCapturePermissionTests.swift`:

```swift
import XCTest
@testable import Auralis

final class AudioCapturePermissionTests: XCTestCase {
    func testMissingUsageDescriptionBlocksTapAttempt() {
        let state = AudioCapturePermissionState(
            screenCapture: .granted,
            audioUsageDescription: .missing
        )

        XCTAssertFalse(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Audio capture usage description missing")
    }

    func testGrantedScreenCaptureAndUsageDescriptionAllowTaps() {
        let state = AudioCapturePermissionState(
            screenCapture: .granted,
            audioUsageDescription: .present
        )

        XCTAssertTrue(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Audio capture ready")
    }

    func testDeniedScreenCaptureBlocksTaps() {
        let state = AudioCapturePermissionState(
            screenCapture: .denied,
            audioUsageDescription: .present
        )

        XCTAssertFalse(state.allowsProcessTaps)
        XCTAssertEqual(state.summary, "Screen & System Audio Recording denied")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioCapturePermissionTests
```

Expected: compile failure for missing permission types.

- [ ] **Step 3: Implement permission model**

Create `AudioCapturePermission.swift`:

```swift
import Foundation

enum ScreenCapturePermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

enum AudioUsageDescriptionStatus: Equatable {
    case present
    case missing
}

struct AudioCapturePermissionState: Equatable {
    var screenCapture: ScreenCapturePermissionStatus
    var audioUsageDescription: AudioUsageDescriptionStatus

    var allowsProcessTaps: Bool {
        screenCapture == .granted && audioUsageDescription == .present
    }

    var summary: String {
        if audioUsageDescription == .missing {
            return "Audio capture usage description missing"
        }

        switch screenCapture {
        case .notDetermined:
            return "Screen & System Audio Recording not requested"
        case .granted:
            return "Audio capture ready"
        case .denied:
            return "Screen & System Audio Recording denied"
        }
    }

    static let unknown = AudioCapturePermissionState(
        screenCapture: .notDetermined,
        audioUsageDescription: .missing
    )
}
```

- [ ] **Step 4: Run tests**

Run:

```sh
swift test --filter AudioCapturePermissionTests
```

Expected: PASS.

## Task 2: Permission Client

**Files:**
- Create: `Sources/Auralis/Permissions/AudioCapturePermissionClient.swift`
- Test: `Tests/AuralisTests/AudioCapturePermissionTests.swift`

- [ ] **Step 1: Write failing URL test**

Add:

```swift
func testPrivacySettingsURLIsStable() {
    XCTAssertEqual(
        SystemAudioCapturePermissionClient.privacySettingsURL.absoluteString,
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioCapturePermissionTests/testPrivacySettingsURLIsStable
```

Expected: compile failure for missing client.

- [ ] **Step 3: Implement client**

Create `AudioCapturePermissionClient.swift`:

```swift
import AppKit
import CoreGraphics
import Foundation

protocol AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState
    func requestScreenCaptureAccess() -> AudioCapturePermissionState
    func openPrivacySettings()
}

struct SystemAudioCapturePermissionClient: AudioCapturePermissionClient {
    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    var workspace: NSWorkspace = .shared

    func currentState() -> AudioCapturePermissionState {
        AudioCapturePermissionState(
            screenCapture: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined,
            audioUsageDescription: hasAudioUsageDescription ? .present : .missing
        )
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState {
        let granted = CGRequestScreenCaptureAccess()
        return AudioCapturePermissionState(
            screenCapture: granted ? .granted : .denied,
            audioUsageDescription: hasAudioUsageDescription ? .present : .missing
        )
    }

    func openPrivacySettings() {
        workspace.open(Self.privacySettingsURL)
    }

    private var hasAudioUsageDescription: Bool {
        guard let value = infoDictionary["NSAudioCaptureUsageDescription"] as? String else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
```

- [ ] **Step 4: Run tests and build**

Run:

```sh
swift test --filter AudioCapturePermissionTests
swift build
```

Expected: tests pass and build succeeds.

## Task 3: Store Integration

**Files:**
- Modify: `Sources/Auralis/State/AudioControlStore.swift`
- Test: `Tests/AuralisTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write failing store test**

Add fake client to `AudioControlStoreTests`:

```swift
private struct FakePermissionClient: AudioCapturePermissionClient {
    var state: AudioCapturePermissionState

    func currentState() -> AudioCapturePermissionState {
        state
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState {
        state
    }

    func openPrivacySettings() {}
}
```

Add test:

```swift
func testPermissionRefreshUpdatesPublishedStateAndStatus() throws {
    let client = FakePermissionClient(state: AudioCapturePermissionState(
        screenCapture: .denied,
        audioUsageDescription: .present
    ))
    let store = try makeStore(backend: MockAudioBackend(), permissionClient: client)

    store.refreshPermissionState()

    XCTAssertEqual(store.permissionState.summary, "Screen & System Audio Recording denied")
    XCTAssertEqual(store.statusMessage, "Screen & System Audio Recording denied")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testPermissionRefreshUpdatesPublishedStateAndStatus
```

Expected: compile failure for missing store properties/init.

- [ ] **Step 3: Add store dependency and methods**

In `AudioControlStore`, add:

```swift
private let permissionClient: any AudioCapturePermissionClient

@Published private(set) var permissionState: AudioCapturePermissionState = .unknown
```

Change initializer signature:

```swift
init(
    settingsStore: SettingsStore = SettingsStore(),
    backend: any AudioBackend = MockAudioBackend(),
    permissionClient: any AudioCapturePermissionClient = SystemAudioCapturePermissionClient()
) throws {
    self.settingsStore = settingsStore
    self.backend = backend
    self.permissionClient = permissionClient
    self.settings = try settingsStore.load()
    self.permissionState = permissionClient.currentState()
    rebuildDisplayRows()
}
```

Add methods:

```swift
func refreshPermissionState() {
    permissionState = permissionClient.currentState()
    if !permissionState.allowsProcessTaps {
        statusMessage = permissionState.summary
    }
}

func requestAudioCapturePermission() {
    permissionState = permissionClient.requestScreenCaptureAccess()
    statusMessage = permissionState.summary
}

func openAudioCapturePrivacySettings() {
    permissionClient.openPrivacySettings()
}
```

- [ ] **Step 4: Update test helper**

Change `makeStore` helper:

```swift
private func makeStore(
    backend: MockAudioBackend,
    permissionClient: any AudioCapturePermissionClient = FakePermissionClient(
        state: AudioCapturePermissionState(screenCapture: .granted, audioUsageDescription: .present)
    )
) throws -> AudioControlStore {
    let store = SettingsStore(settingsURL: uniqueSettingsURL())
    return try AudioControlStore(settingsStore: store, backend: backend, permissionClient: permissionClient)
}
```

- [ ] **Step 5: Run focused tests**

Run:

```sh
swift test --filter AudioControlStoreTests
```

Expected: PASS.

## Task 4: Popup And Settings UI

**Files:**
- Modify: `Sources/Auralis/Views/MenuBarRootView.swift`
- Modify: `Sources/Auralis/Views/SettingsView.swift`

- [ ] **Step 1: Add popup permission banner**

In `MenuBarRootView.body`, below `header`, add:

```swift
if !store.permissionState.allowsProcessTaps {
    VStack(alignment: .leading, spacing: 8) {
        Text(store.permissionState.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Button("Request Access") {
                store.requestAudioCapturePermission()
            }
            Button("Open Settings") {
                store.openAudioCapturePrivacySettings()
            }
        }
    }
    .padding(10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
}
```

- [ ] **Step 2: Add settings permission section**

In `SettingsView.Form`, after backend section, add:

```swift
Section("Permissions") {
    Text(store.permissionState.summary)
        .foregroundStyle(store.permissionState.allowsProcessTaps ? .secondary : .primary)

    HStack {
        Button("Request Screen & System Audio Recording") {
            store.requestAudioCapturePermission()
        }
        Button("Open Privacy Settings") {
            store.openAudioCapturePrivacySettings()
        }
    }
}
```

- [ ] **Step 3: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

## Task 5: Development App Bundle Metadata

**Files:**
- Create: `Resources/Auralis-Info.plist`
- Create: `Scripts/build-debug-app.sh`
- Modify: `README.md`

- [ ] **Step 1: Add Info.plist**

Create `Resources/Auralis-Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Auralis</string>
    <key>CFBundleIdentifier</key>
    <string>com.michaeltrannhan.Auralis</string>
    <key>CFBundleName</key>
    <string>Auralis</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Auralis needs Screen &amp; System Audio Recording access to apply per-app volume and EQ using Core Audio process taps.</string>
</dict>
</plist>
```

- [ ] **Step 2: Add debug bundle script**

Create `Scripts/build-debug-app.sh`:

```sh
#!/bin/sh
set -eu

swift build

APP_DIR=".build/Auralis.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp ".build/debug/Auralis" "$MACOS_DIR/Auralis"
cp "Resources/Auralis-Info.plist" "$CONTENTS_DIR/Info.plist"

echo "$APP_DIR"
```

- [ ] **Step 3: Make script executable**

Run:

```sh
chmod +x Scripts/build-debug-app.sh
```

- [ ] **Step 4: Run script**

Run:

```sh
Scripts/build-debug-app.sh
```

Expected: prints `.build/Auralis.app`.

- [ ] **Step 5: Document run path**

Update `README.md` build section:

````md
For permission testing, run the debug app bundle so macOS can read `NSAudioCaptureUsageDescription`:

```sh
Scripts/build-debug-app.sh
open .build/Auralis.app
```
````

## Task 6: Documentation And Tracker Update

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update flows**

Add permission flow:

```md
## Permission Flow

CoreAudio process taps require Screen & System Audio Recording permission and an `NSAudioCaptureUsageDescription` value in the app bundle. Auralis detects both before future tap phases attempt tap creation. When either condition is missing, the popup shows a permission banner and keeps discovery mode usable.
```

- [ ] **Step 2: Update tracker when phase completes**

After implementation and verification, change Phase 1 status from `Planned` to `Complete`, and set active phase to Phase 2.

## Task 7: Verification

**Files:**
- No code edits.

- [ ] **Step 1: Run focused tests**

Run:

```sh
swift test --filter AudioCapturePermissionTests
swift test --filter AudioControlStoreTests
```

Expected: both pass.

- [ ] **Step 2: Run full tests**

Run:

```sh
swift test
```

Expected: all tests pass.

- [ ] **Step 3: Build**

Run:

```sh
swift build
```

Expected: build succeeds.

- [ ] **Step 4: Build debug app bundle**

Run:

```sh
Scripts/build-debug-app.sh
```

Expected: `.build/Auralis.app` exists and contains `Contents/Info.plist`.

- [ ] **Step 5: Manual permission check**

Run:

```sh
open .build/Auralis.app
```

Manual checks:

- Open popup.
- Confirm permission state appears.
- Click Request Access.
- Confirm macOS prompt or settings path appears.
- Deny or leave unapproved.
- Confirm discovery mode remains usable.
- Approve access in System Settings if testing real grant.
- Relaunch app.
- Confirm state updates to ready.

## Review Notes

Phase 1 still must not create process taps. It only detects permission state, guides the user, and makes the app-bundle metadata requirement explicit.
