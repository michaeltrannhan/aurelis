# Phase 7 Popup And Settings Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the popup and settings experience close to FineTune usability while staying on the existing EQMacRep architecture.

**Architecture:** Split settings into tabs, add reusable settings rows, add popup keyboard navigation, improve row controls, add edit mode for pin/ignore/order, and make popup dimensions safe on small screens. Keep all UI state backed by existing persisted settings and backend commands.

**Tech Stack:** SwiftUI, AppKit settings window integration, XCTest for pure UI models, `swift build` for view validation.

---

## Reference Notes

FineTune separates settings into General, Audio, Shortcuts, Updates, and About tabs. Its popup has keyboard navigation, scroll-wheel volume adjustment, compact row controls, editable percentages, route/device sections, and edit-mode list management.

Phase 7 intentionally avoids media-key interception, HUD windows, input devices, presets, AutoEQ, and advanced device inspector work. Those are Phase 8, Phase 9, Phase 11, and Phase 13.

## File Structure

- Create `Sources/EQMacRep/Views/Settings/SettingsRootView.swift`: tabbed settings root.
- Create `Sources/EQMacRep/Views/Settings/SettingsSectionView.swift`: shared settings section and row components.
- Create `Sources/EQMacRep/Views/Settings/GeneralSettingsTab.swift`: appearance, launch, popup size, reset.
- Create `Sources/EQMacRep/Views/Settings/AudioSettingsTab.swift`: default volume, EQ range, backend, inactive apps.
- Create `Sources/EQMacRep/Views/Settings/ShortcutsSettingsTab.swift`: volume step plus disabled Phase 8 controls with explanatory labels.
- Create `Sources/EQMacRep/Views/Settings/UpdatesSettingsTab.swift`: version display and manual update label for the Phase 13 update path.
- Create `Sources/EQMacRep/Views/Settings/AboutSettingsTab.swift`: app version, repository/license links.
- Create `Sources/EQMacRep/Views/PopupKeyboardNavModel.swift`: pure keyboard row ordering.
- Create `Sources/EQMacRep/Views/ScrollWheelStepModifier.swift`: scroll-wheel volume stepping.
- Modify `Sources/EQMacRep/Views/SettingsView.swift`: replace old form with `SettingsRootView`.
- Modify `Sources/EQMacRep/Views/MenuBarRootView.swift`: add edit mode, keyboard navigation, safe max height.
- Modify `Sources/EQMacRep/Views/AppRowView.swift`: truncation, tooltips, editable percentage, scroll-wheel step.
- Modify `Sources/EQMacRep/Domain/AppCustomization.swift`: add launch-at-login intent, popup max height, settings tab state support, and shared color-scheme mapping.
- Modify `Sources/EQMacRep/Persistence/SettingsStore.swift`: add app display order.
- Modify `Sources/EQMacRep/State/AudioControlStore.swift`: merge and persist app display order.
- Test `Tests/EQMacRepTests/PopupKeyboardNavModelTests.swift`.
- Test `Tests/EQMacRepTests/AudioControlStoreTests.swift`: app ordering and edit actions.
- Test `Tests/EQMacRepTests/CustomizationTests.swift`: popup dimensions.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Settings Tabs

**Files:**
- Create: `Sources/EQMacRep/Views/Settings/SettingsRootView.swift`
- Create: `Sources/EQMacRep/Views/Settings/SettingsSectionView.swift`
- Create: tab files listed above
- Modify: `Sources/EQMacRep/Views/SettingsView.swift`
- Test: `Tests/EQMacRepTests/CustomizationTests.swift`

- [ ] **Step 1: Write settings enum tests**

Add:

```swift
func testSettingsTabsExposeExpectedSections() {
    XCTAssertEqual(SettingsTab.allCases.map(\.label), ["General", "Audio", "Shortcuts", "Updates", "About"])
    XCTAssertEqual(SettingsTab.general.systemImage, "gearshape")
    XCTAssertEqual(SettingsTab.audio.systemImage, "speaker.wave.2")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testSettingsTabsExposeExpectedSections
```

Expected: compile failure for missing `SettingsTab`.

- [ ] **Step 3: Add settings tab model**

Add:

```swift
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case audio
    case shortcuts
    case updates
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .shortcuts: return "Shortcuts"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .audio: return "speaker.wave.2"
        case .shortcuts: return "command"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}
```

- [ ] **Step 4: Build settings root**

Implement `SettingsRootView`:

```swift
struct SettingsRootView: View {
    @ObservedObject var store: AudioControlStore
    @State private var selection: SettingsTab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab(store: store).tabItem { Label(SettingsTab.general.label, systemImage: SettingsTab.general.systemImage) }.tag(SettingsTab.general)
            AudioSettingsTab(store: store).tabItem { Label(SettingsTab.audio.label, systemImage: SettingsTab.audio.systemImage) }.tag(SettingsTab.audio)
            ShortcutsSettingsTab(store: store).tabItem { Label(SettingsTab.shortcuts.label, systemImage: SettingsTab.shortcuts.systemImage) }.tag(SettingsTab.shortcuts)
            UpdatesSettingsTab().tabItem { Label(SettingsTab.updates.label, systemImage: SettingsTab.updates.systemImage) }.tag(SettingsTab.updates)
            AboutSettingsTab().tabItem { Label(SettingsTab.about.label, systemImage: SettingsTab.about.systemImage) }.tag(SettingsTab.about)
        }
        .frame(width: 720, height: 560)
        .preferredColorScheme(store.settings.customization.appearance.colorScheme)
    }
}
```

Keep `SettingsView` as a compatibility wrapper that returns `SettingsRootView(store: store)`. Move the current private `AppAppearance.colorScheme` helper from `MenuBarRootView.swift` into a non-private extension near `AppAppearance` so settings and popup can share it.

- [ ] **Step 5: Run tests and build**

Run:

```sh
swift test --filter CustomizationTests/testSettingsTabsExposeExpectedSections
swift build
```

Expected: PASS and build succeeds.

## Task 2: Popup Dimensions And Safe Height

**Files:**
- Modify: `Sources/EQMacRep/Domain/AppCustomization.swift`
- Modify: `Sources/EQMacRep/Views/MenuBarRootView.swift`
- Test: `Tests/EQMacRepTests/CustomizationTests.swift`

- [ ] **Step 1: Write dimensions test**

Add:

```swift
func testPopupDimensionsIncludeMaxContentHeight() {
    XCTAssertLessThan(PopupDensity.compact.dimensions.maxContentHeight, PopupDensity.spacious.dimensions.maxContentHeight)
    XCTAssertGreaterThan(PopupDensity.comfortable.dimensions.maxContentHeight, 300)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testPopupDimensionsIncludeMaxContentHeight
```

Expected: compile failure for missing `maxContentHeight`.

- [ ] **Step 3: Add max height**

Extend `PopupDimensions`:

```swift
var maxContentHeight: Double
```

Set:

```swift
case .compact: PopupDimensions(width: 420, rowHeight: 48, contentPadding: 10, maxContentHeight: 420)
case .comfortable: PopupDimensions(width: 500, rowHeight: 60, contentPadding: 14, maxContentHeight: 560)
case .spacious: PopupDimensions(width: 580, rowHeight: 74, contentPadding: 18, maxContentHeight: 680)
```

Use `dimensions.maxContentHeight` for the popup scroll view max height.

- [ ] **Step 4: Run dimensions tests**

Run:

```sh
swift test --filter CustomizationTests/testPopupDimensionsIncludeMaxContentHeight
```

Expected: PASS.

## Task 3: Keyboard Navigation Model

**Files:**
- Create: `Sources/EQMacRep/Views/PopupKeyboardNavModel.swift`
- Modify: `Sources/EQMacRep/Views/MenuBarRootView.swift`
- Test: `Tests/EQMacRepTests/PopupKeyboardNavModelTests.swift`

- [ ] **Step 1: Write failing navigation tests**

Create `PopupKeyboardNavModelTests.swift`:

```swift
import XCTest
@testable import EQMacRep

@MainActor
final class PopupKeyboardNavModelTests: XCTestCase {
    func testNextAndPreviousFollowVisibleRows() {
        let nav = PopupKeyboardNavModel()
        let music = AudioAppIdentity(rawValue: "com.example.Music")
        let safari = AudioAppIdentity(rawValue: "com.example.Safari")

        nav.sync(apps: [music, safari], isEditing: false)

        XCTAssertEqual(nav.next(after: nil), music)
        XCTAssertEqual(nav.next(after: music), safari)
        XCTAssertEqual(nav.previous(before: safari), music)
    }

    func testEditingClearsKeyboardOrder() {
        let nav = PopupKeyboardNavModel()

        nav.sync(apps: [AudioAppIdentity(rawValue: "com.example.Music")], isEditing: true)

        XCTAssertNil(nav.next(after: nil))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter PopupKeyboardNavModelTests
```

Expected: compile failure for missing model.

- [ ] **Step 3: Implement model**

Create:

```swift
@MainActor
final class PopupKeyboardNavModel {
    private(set) var orderedAppIDs: [AudioAppIdentity] = []

    func sync(apps: [AudioAppIdentity], isEditing: Bool) {
        orderedAppIDs = isEditing ? [] : apps
    }

    func next(after current: AudioAppIdentity?) -> AudioAppIdentity? {
        guard !orderedAppIDs.isEmpty else { return nil }
        guard let current,
              let index = orderedAppIDs.firstIndex(of: current) else {
            return orderedAppIDs.first
        }
        let nextIndex = index + 1
        return nextIndex < orderedAppIDs.count ? orderedAppIDs[nextIndex] : nil
    }

    func previous(before current: AudioAppIdentity?) -> AudioAppIdentity? {
        guard let current,
              let index = orderedAppIDs.firstIndex(of: current),
              index > 0 else {
            return nil
        }
        return orderedAppIDs[index - 1]
    }
}
```

- [ ] **Step 4: Wire keys**

In `MenuBarRootView`, listen for:

- Down arrow: select `nav.next(after: selectedAppID)`
- Up arrow: select `nav.previous(before: selectedAppID)`
- Return or Space: toggle mute for selected row
- Escape: clear selection

- [ ] **Step 5: Run navigation tests and build**

Run:

```sh
swift test --filter PopupKeyboardNavModelTests
swift build
```

Expected: PASS and build succeeds.

## Task 4: Scroll-Wheel Volume And Editable Percent

**Files:**
- Create: `Sources/EQMacRep/Views/ScrollWheelStepModifier.swift`
- Modify: `Sources/EQMacRep/Views/AppRowView.swift`
- Test: `Tests/EQMacRepTests/CustomizationTests.swift`

- [ ] **Step 1: Write clamp helper test**

Add:

```swift
func testScrollWheelStepClampsVolume() {
    XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 0.5, deltaY: -1, step: 0.05), 0.55, accuracy: 0.0001)
    XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 1, deltaY: -1, step: 0.05), 1, accuracy: 0.0001)
    XCTAssertEqual(ScrollWheelStepModel.nextValue(current: 0, deltaY: 1, step: 0.05), 0, accuracy: 0.0001)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter CustomizationTests/testScrollWheelStepClampsVolume
```

Expected: compile failure for missing model.

- [ ] **Step 3: Implement helper and modifier**

Add:

```swift
enum ScrollWheelStepModel {
    static func nextValue(current: Double, deltaY: Double, step: Double) -> Double {
        let direction = deltaY < 0 ? 1.0 : -1.0
        return AppCustomization.clampedVolume(current + direction * step, fallback: current)
    }
}
```

Create a SwiftUI modifier that handles `onContinuousHover` plus an `NSViewRepresentable` event monitor for scroll events inside the row. Apply it to the volume slider in `AppRowView` using `store.settings.customization.volumeStep.fraction`.

Replace static percent text with an editable percent `TextField` that writes back through `onVolume`.

- [ ] **Step 4: Run tests and build**

Run:

```sh
swift test --filter CustomizationTests/testScrollWheelStepClampsVolume
swift build
```

Expected: PASS and build succeeds.

## Task 5: Edit Mode, Ignore, Pin, And Reorder

**Files:**
- Modify: `Sources/EQMacRep/Persistence/SettingsStore.swift`
- Modify: `Sources/EQMacRep/State/AudioControlStore.swift`
- Modify: `Sources/EQMacRep/Views/MenuBarRootView.swift`
- Modify: `Sources/EQMacRep/Views/AppRowView.swift`
- Test: `Tests/EQMacRepTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write order merge test**

Add:

```swift
func testAppDisplayOrderMergesNewAppsAtEnd() throws {
    let music = AudioAppIdentity(rawValue: "com.example.Music")
    let safari = AudioAppIdentity(rawValue: "com.example.Safari")
    let browser = AudioAppIdentity(rawValue: "com.example.Browser")
    let backend = MockAudioBackend(apps: [
        AudioAppSnapshot(identity: music, displayName: "Music"),
        AudioAppSnapshot(identity: safari, displayName: "Safari")
    ])
    let store = try makeStore(backend: backend)
    try store.refresh()
    try store.moveApp(safari, before: music)

    backend.snapshot.apps.append(AudioAppSnapshot(identity: browser, displayName: "Browser"))
    try store.refresh()

    XCTAssertEqual(store.displayRows.map(\.identity), [safari, music, browser])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testAppDisplayOrderMergesNewAppsAtEnd
```

Expected: compile failure for missing app order state and move method.

- [ ] **Step 3: Persist app order**

Add to `PersistedSettings`:

```swift
var appDisplayOrder: [AudioAppIdentity]
```

Default it to `[]`. Decode missing value as `[]` in `PersistedSettings.init(from:)`.

- [ ] **Step 4: Implement merge and move**

In `AudioControlStore.refresh()`, after settings are ensured:

```swift
mergeAppDisplayOrder()
```

Implement:

```swift
func moveApp(_ identity: AudioAppIdentity, before target: AudioAppIdentity) throws
```

`rebuildDisplayRows()` sorts by `appDisplayOrder` first, then pinned/active/display name for identities not yet in the order list.

- [ ] **Step 5: Add edit UI**

In `MenuBarRootView`, add an edit toggle. In edit mode:

- show drag handles
- show pin/unpin
- show ignore/unignore
- hide EQ panel
- disable keyboard navigation model

- [ ] **Step 6: Run edit-mode tests and build**

Run:

```sh
swift test --filter AudioControlStoreTests/testAppDisplayOrderMergesNewAppsAtEnd
swift build
```

Expected: PASS and build succeeds.

## Task 6: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- settings tab layout
- popup safe sizing
- keyboard navigation
- scroll-wheel volume
- edit mode and app order
- route picker from Phase 5 remains in row controls

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter PopupKeyboardNavModelTests
swift test --filter AudioControlStoreTests
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

- [ ] **Step 4: Manual UI test**

Run:

```sh
open .build/EQMacRep.app
```

Manual checks:

- Settings opens with General, Audio, Shortcuts, Updates, and About tabs.
- Popup fits on a small laptop screen.
- Arrow keys move selected row.
- Space toggles mute for selected row.
- Escape clears selection.
- Scroll wheel changes row volume.
- Percent field edits volume.
- Edit mode reorders apps and persists after relaunch.
- Ignore hides app and tears down tap according to Phase 6 behavior.

## Review Notes

Phase 7 should improve usability without changing audio graph ownership. Keep media keys, HUD windows, input devices, presets, and inspector out of this phase.
