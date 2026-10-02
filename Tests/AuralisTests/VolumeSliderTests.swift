import AppKit
import XCTest
@testable import Auralis

@MainActor
final class VolumeSliderTests: XCTestCase {
    func testWheelUsesConfiguredStepsAndTeardownFlushesOnce() throws {
        let slider = NativeVolumeSlider()
        slider.cell = VolumeSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0.5
        slider.volumeStep = 0.05
        let receiver = SliderReceiver()
        slider.target = receiver
        slider.action = #selector(SliderReceiver.changed(_:))
        var editing: [Bool] = []
        slider.onEditingChanged = { editing.append($0) }
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
            wheel1: -1, wheel2: 0, wheel3: 0
        ))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        slider.scrollWheel(with: event)
        XCTAssertEqual(slider.doubleValue, 0.55, accuracy: 0.0001)
        XCTAssertEqual(receiver.values.last, slider.doubleValue)
        XCTAssertEqual(editing, [true])
        slider.finishWheelEditing()
        slider.finishWheelEditing()
        XCTAssertEqual(editing, [true, false])
    }

    func testAccessibilityAdjustmentSendsValueAndEndsContinuousEditing() {
        let slider = NativeVolumeSlider()
        slider.cell = VolumeSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0.5
        let receiver = SliderReceiver()
        slider.target = receiver
        slider.action = #selector(SliderReceiver.changed(_:))
        var editing: [Bool] = []
        slider.onEditingChanged = { editing.append($0) }

        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertGreaterThan(slider.doubleValue, 0.5)
        XCTAssertEqual(receiver.values.last, slider.doubleValue)
        XCTAssertEqual(editing, [true, false])
        XCTAssertTrue(slider.accessibilityPerformDecrement())
        XCTAssertEqual(editing, [true, false, true, false])

        slider.isEnabled = false
        let previous = slider.doubleValue
        XCTAssertFalse(slider.accessibilityPerformIncrement())
        XCTAssertEqual(slider.doubleValue, previous)
        XCTAssertEqual(editing.count, 4)
    }
}

@MainActor
private final class SliderReceiver: NSObject {
    var values: [Double] = []
    @objc func changed(_ sender: NSSlider) { values.append(sender.doubleValue) }
}
