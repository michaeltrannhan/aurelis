# Phase 11 EQ Presets And AutoEQ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reusable EQ workflows: built-in presets, user presets, and AutoEQ profiles that update live DSP.

**Architecture:** Built-in and user presets map to existing `EQCurve`. AutoEQ profiles are parametric correction filters stored per output device and applied as a second realtime biquad processor after the app graphic EQ. Profile parsing is pure and validated before any realtime setup swap.

**Tech Stack:** Swift 6, Accelerate/vDSP biquad processor from Phase 4, JSON persistence, SwiftUI picker, XCTest.

---

## Reference Notes

FineTune has built-in EQ presets, user-created EQ presets, AutoEQ profile parsing for EqualizerAPO `ParametricEQ.txt`, profile validation, preamp gain, and realtime parametric correction using the same biquad processor infrastructure as graphic EQ.

Phase 11 intentionally excludes loudness compensation and device volume. Those are Phase 12.

## File Structure

- Create `Sources/EQMacRep/Domain/EQPreset.swift`: built-in preset enum and categories.
- Create `Sources/EQMacRep/Domain/UserEQPreset.swift`: persisted user preset model.
- Create `Sources/EQMacRep/Audio/AutoEQ/AutoEQProfile.swift`: profile/filter models.
- Create `Sources/EQMacRep/Audio/AutoEQ/AutoEQParser.swift`: EqualizerAPO parser.
- Create `Sources/EQMacRep/Audio/CoreAudio/CoreAudioAutoEQProcessor.swift`: parametric realtime processor.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioBiquadMath.swift`: low shelf, high shelf, AutoEQ coefficient helpers.
- Modify `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`: run app EQ then AutoEQ then gain/limiter.
- Modify `Sources/EQMacRep/Persistence/SettingsStore.swift`: user presets and per-device AutoEQ selections.
- Modify `Sources/EQMacRep/State/AudioControlStore.swift`: preset and AutoEQ commands.
- Modify `Sources/EQMacRep/Views/EQPanelView.swift`: preset picker, save, rename, delete.
- Test `Tests/EQMacRepTests/EQPresetTests.swift`.
- Test `Tests/EQMacRepTests/UserEQPresetTests.swift`.
- Test `Tests/EQMacRepTests/AutoEQParserTests.swift`.
- Test `Tests/EQMacRepTests/CoreAudioAutoEQProcessorTests.swift`.
- Test `Tests/EQMacRepTests/AudioControlStoreTests.swift`.
- Update `Documentation/flows.md` and `Documentation/phase-tracker.md`.

## Task 1: Built-In EQ Presets

**Files:**
- Create: `Sources/EQMacRep/Domain/EQPreset.swift`
- Test: `Tests/EQMacRepTests/EQPresetTests.swift`

- [ ] **Step 1: Write preset tests**

Create:

```swift
import XCTest
@testable import EQMacRep

final class EQPresetTests: XCTestCase {
    func testBuiltInPresetsProduceTenBandCurves() {
        for preset in EQPreset.allCases {
            XCTAssertEqual(preset.curve.gains.count, EQCurve.bandCount)
        }
    }

    func testFlatPresetIsNeutral() {
        XCTAssertEqual(EQPreset.flat.curve.gains, Array(repeating: 0, count: EQCurve.bandCount))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter EQPresetTests
```

Expected: compile failure for missing `EQPreset`.

- [ ] **Step 3: Implement built-ins**

Create `EQPreset` with categories:

- Utility: Flat, Bass Boost, Bass Cut, Treble Boost
- Speech: Vocal Clarity, Podcast, Spoken Word
- Listening: Loudness, Late Night, Small Speakers
- Music: Rock, Pop, Electronic, Jazz, Classical, Hip-Hop, R&B, Deep, Acoustic
- Media: Movie

Each case returns an `EQCurve` with exactly 10 gains.

- [ ] **Step 4: Run preset tests**

Run:

```sh
swift test --filter EQPresetTests
```

Expected: PASS.

## Task 2: User Presets

**Files:**
- Create: `Sources/EQMacRep/Domain/UserEQPreset.swift`
- Modify: `Sources/EQMacRep/Persistence/SettingsStore.swift`
- Modify: `Sources/EQMacRep/State/AudioControlStore.swift`
- Test: `Tests/EQMacRepTests/UserEQPresetTests.swift`
- Test: `Tests/EQMacRepTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write user preset tests**

Create:

```swift
import XCTest
@testable import EQMacRep

final class UserEQPresetTests: XCTestCase {
    func testPresetNameFallsBackAndDeduplicates() {
        var collection = UserEQPresetCollection()
        let first = collection.create(name: " Bass ", curve: EQCurve())
        let second = collection.create(name: "Bass", curve: EQCurve())
        let third = collection.create(name: "   ", curve: EQCurve())

        XCTAssertEqual(first.name, "Bass")
        XCTAssertEqual(second.name, "Bass (2)")
        XCTAssertEqual(third.name, "Untitled")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter UserEQPresetTests
```

Expected: compile failure for missing models.

- [ ] **Step 3: Implement user preset models**

Add:

```swift
struct UserEQPreset: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var curve: EQCurve
    var createdAt: Date
}

struct UserEQPresetCollection: Codable, Equatable {
    var presets: [UserEQPreset] = []
    mutating func create(name: String, curve: EQCurve) -> UserEQPreset
    mutating func rename(id: UUID, name: String)
    mutating func delete(id: UUID)
}
```

Deduplicate names with Finder-style suffixes: `Name (2)`, `Name (3)`.

- [ ] **Step 4: Persist and expose**

Add to `PersistedSettings`:

```swift
var userEQPresets: UserEQPresetCollection
```

Add store methods:

```swift
func createUserEQPreset(name: String, from identity: AudioAppIdentity) throws
func applyUserEQPreset(_ presetID: UUID, to identity: AudioAppIdentity) throws
func renameUserEQPreset(_ presetID: UUID, name: String) throws
func deleteUserEQPreset(_ presetID: UUID) throws
```

- [ ] **Step 5: Run user preset tests**

Run:

```sh
swift test --filter UserEQPresetTests
swift test --filter AudioControlStoreTests
```

Expected: PASS.

## Task 3: Preset Picker UI

**Files:**
- Modify: `Sources/EQMacRep/Views/EQPanelView.swift`
- Create: `Sources/EQMacRep/Views/EQPresetPickerView.swift`
- Test: `Tests/EQMacRepTests/EQPresetTests.swift`

- [ ] **Step 1: Write picker section test**

Add:

```swift
func testPresetPickerSectionsIncludeUserPresetsFirst() {
    let sections = EQPresetPickerSection.sections(userPresetCount: 2)

    XCTAssertEqual(sections.first, .userPresets)
    XCTAssertTrue(sections.contains(.builtIn(.music)))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter EQPresetTests/testPresetPickerSectionsIncludeUserPresetsFirst
```

Expected: compile failure for missing picker section model.

- [ ] **Step 3: Implement picker state**

Create `EQPresetPickerSection` and `EQPresetPickerItem`. Built-in and user presets share one picker. User preset rows expose rename and delete actions.

- [ ] **Step 4: Wire EQ panel**

`EQPanelView` receives:

- `userPresets`
- `onBuiltInPreset`
- `onUserPreset`
- `onSavePreset`
- `onRenamePreset`
- `onDeletePreset`

Applying a preset updates `EQCurve` through `AudioControlStore.setEQGain` or a new `setEQCurve` method, then forwards `.setEQ` to the backend.

- [ ] **Step 5: Run build**

Run:

```sh
swift test --filter EQPresetTests/testPresetPickerSectionsIncludeUserPresetsFirst
swift build
```

Expected: PASS and build succeeds.

## Task 4: AutoEQ Parser And Profile Model

**Files:**
- Create: `Sources/EQMacRep/Audio/AutoEQ/AutoEQProfile.swift`
- Create: `Sources/EQMacRep/Audio/AutoEQ/AutoEQParser.swift`
- Test: `Tests/EQMacRepTests/AutoEQParserTests.swift`

- [ ] **Step 1: Write parser tests**

Create:

```swift
import XCTest
@testable import EQMacRep

final class AutoEQParserTests: XCTestCase {
    func testParsesParametricEQText() {
        let text = """
        Preamp: -6.2 dB
        Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41
        Filter 2: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71
        """

        let profile = AutoEQParser.parse(text: text, name: "Headphones", source: .imported)

        XCTAssertEqual(profile?.preampDB, -6.2, accuracy: 0.001)
        XCTAssertEqual(profile?.filters.count, 2)
        XCTAssertEqual(profile?.filters[1].type, .lowShelf)
    }
}
```

- [ ] **Step 2: Run parser test to verify it fails**

Run:

```sh
swift test --filter AutoEQParserTests
```

Expected: compile failure for missing parser.

- [ ] **Step 3: Implement profile and parser**

Add models:

```swift
struct AutoEQFilter: Codable, Equatable
struct AutoEQProfile: Codable, Equatable, Identifiable
enum AutoEQSource: String, Codable
```

Parser rules:

- parse `Preamp:`
- parse enabled filters only
- support `PK`, `PEQ`, `LS`, `LSC`, `HS`, `HSC`
- reject nonpositive frequency
- reject nonpositive Q
- reject absolute gain above 30 dB
- cap filters at 10
- return nil when no filters are valid

- [ ] **Step 4: Run parser tests**

Run:

```sh
swift test --filter AutoEQParserTests
```

Expected: PASS.

## Task 5: AutoEQ Realtime Processor

**Files:**
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioBiquadMath.swift`
- Create: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioAutoEQProcessor.swift`
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioTapIOController.swift`
- Test: `Tests/EQMacRepTests/CoreAudioAutoEQProcessorTests.swift`

- [ ] **Step 1: Write processor tests**

Create:

```swift
import XCTest
@testable import EQMacRep

final class CoreAudioAutoEQProcessorTests: XCTestCase {
    func testNilProfileCopiesInput() {
        let processor = CoreAudioAutoEQProcessor(sampleRate: 48000)
        let input: [Float] = [0.1, 0.1, -0.1, -0.1]
        var output = Array(repeating: Float(0), count: input.count)

        processor.updateProfile(nil)
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                processor.process(input: inputBuffer.baseAddress!, output: outputBuffer.baseAddress!, frameCount: 2)
            }
        }

        XCTAssertEqual(output, input)
    }
}
```

- [ ] **Step 2: Run processor test to verify it fails**

Run:

```sh
swift test --filter CoreAudioAutoEQProcessorTests
```

Expected: compile failure for missing processor.

- [ ] **Step 3: Add shelf math**

Add RBJ low-shelf and high-shelf coefficient functions to `CoreAudioBiquadMath`. Add:

```swift
static func coefficientsForAutoEQFilters(_ filters: [AutoEQFilter], sampleRate: Double, profileOptimizedRate: Double) -> [Double]
```

Bypass invalid or above-Nyquist filters with unity coefficients.

- [ ] **Step 4: Implement processor**

`CoreAudioAutoEQProcessor` wraps `CoreAudioBiquadProcessor`, stores the current profile, converts preamp dB to linear gain, and applies preamp before the biquad cascade. Profile update occurs outside the realtime callback.

- [ ] **Step 5: Wire tap path**

In `CoreAudioTapIOController.processStereoFrames`:

1. graphic EQ
2. AutoEQ
3. volume/mute/boost gain
4. limiter

- [ ] **Step 6: Run processor tests**

Run:

```sh
swift test --filter CoreAudioAutoEQProcessorTests
swift test --filter CoreAudioTapLifecycleTests
```

Expected: PASS.

## Task 6: Device AutoEQ Selection

**Files:**
- Modify: `Sources/EQMacRep/Persistence/SettingsStore.swift`
- Modify: `Sources/EQMacRep/State/AudioControlStore.swift`
- Modify: `Sources/EQMacRep/Audio/CoreAudio/CoreAudioProcessTapManager.swift`
- Test: `Tests/EQMacRepTests/AudioControlStoreTests.swift`

- [ ] **Step 1: Write selection persistence test**

Add:

```swift
func testAutoEQSelectionPersistsPerDevice() throws {
    let backend = MockAudioBackend()
    let store = try makeStore(backend: backend)
    let profile = AutoEQProfile(id: "hd600", name: "HD 600", source: .imported, preampDB: -6, filters: [])

    try store.saveAutoEQProfile(profile)
    try store.setAutoEQSelection(profileID: "hd600", forOutputDeviceID: "usb", enabled: true)

    let saved = try store.settingsStore.load()
    XCTAssertEqual(saved.autoEQSelectionsByOutputDeviceID["usb"]?.profileID, "hd600")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```sh
swift test --filter AudioControlStoreTests/testAutoEQSelectionPersistsPerDevice
```

Expected: compile failure for missing AutoEQ settings.

- [ ] **Step 3: Persist profiles and selections**

Add to `PersistedSettings`:

```swift
var autoEQProfilesByID: [String: AutoEQProfile]
var autoEQSelectionsByOutputDeviceID: [String: AutoEQSelection]
```

Add store methods from the test. Manager receives profile changes and updates active controllers whose resolved output device matches the selection.

- [ ] **Step 4: Run selection tests**

Run:

```sh
swift test --filter AudioControlStoreTests/testAutoEQSelectionPersistsPerDevice
```

Expected: PASS.

## Task 7: Verification

**Files:**
- Modify: `Documentation/flows.md`
- Modify: `Documentation/phase-tracker.md`

- [ ] **Step 1: Update docs**

Document:

- built-in preset categories
- user preset naming rules
- AutoEQ profile parser format
- AutoEQ per-output-device selection
- DSP order: graphic EQ, AutoEQ, gain, limiter

- [ ] **Step 2: Run focused tests**

Run:

```sh
swift test --filter EQPresetTests
swift test --filter UserEQPresetTests
swift test --filter AutoEQParserTests
swift test --filter CoreAudioAutoEQProcessorTests
swift test --filter AudioControlStoreTests
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

- [ ] **Step 4: Manual EQ workflow test**

Run:

```sh
open .build/EQMacRep.app
```

Manual checks:

- Apply built-in preset and confirm EQ sliders update.
- Save a custom preset, rename it, delete it, relaunch, and confirm persistence.
- Import AutoEQ text and confirm profile appears.
- Enable AutoEQ for selected output device and confirm active app audio changes.
- Disable AutoEQ and confirm audio returns to graphic EQ only.

## Review Notes

Phase 11 is EQ workflow only. Keep loudness, DDC, alert volume, and inspector out of this phase.
