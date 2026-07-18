import Foundation
import XCTest
@testable import EQMacRep

@MainActor
final class AppLifecycleCoordinatorTests: XCTestCase {
    func testStartupIsSceneIndependentOrderedAndIdempotent() async throws {
        let events = LifecycleEventLog()
        let controls = RecordingExternalControls(events: events)
        let widget = RecordingWidgetLifecycle(events: events)
        let store = try makeStore(backend: MockAudioBackend())
        let lifecycle = AppLifecycleCoordinator(
            store: store,
            controls: controls,
            widgetBridge: widget
        )

        let first = await lifecycle.start()
        let second = await lifecycle.start()

        XCTAssertEqual(first, second)
        XCTAssertNil(first.discoveryErrorDescription)
        XCTAssertTrue(first.observationStarted)
        XCTAssertTrue(first.externalControlsStarted)
        XCTAssertTrue(first.widgetTransportStarted)
        XCTAssertEqual(controls.startCount, 1)
        XCTAssertEqual(widget.startCount, 1)
        XCTAssertEqual(events.values, ["controls.start", "widget.start"])
        XCTAssertFalse(store.displayRows.isEmpty, "Discovery must not depend on opening a scene")

        let firstStop = await lifecycle.stop()
        let secondStop = await lifecycle.stop()
        XCTAssertEqual(firstStop, secondStop)
        XCTAssertEqual(controls.stopCount, 1)
        XCTAssertEqual(widget.stopCount, 1)
        XCTAssertEqual(events.values.suffix(2), ["controls.stop", "widget.stop"])
    }

    func testDiscoveryFailureDoesNotBlockControlsObservationOrWidgetStartup() async throws {
        let backend = MockAudioBackend()
        backend.fetchError = LifecycleTestError.discovery
        let controls = RecordingExternalControls()
        let widget = RecordingWidgetLifecycle()
        let store = try makeStore(backend: backend)
        let lifecycle = AppLifecycleCoordinator(
            store: store,
            controls: controls,
            widgetBridge: widget
        )

        let report = await lifecycle.start()

        XCTAssertNotNil(report.discoveryErrorDescription)
        XCTAssertTrue(report.observationStarted)
        XCTAssertTrue(report.externalControlsStarted)
        XCTAssertTrue(report.widgetTransportStarted)
        XCTAssertEqual(controls.startCount, 1)
        XCTAssertEqual(widget.startCount, 1)
        _ = await lifecycle.stop()
    }

    func testWidgetStartupFailureIsReportedWithoutUndoingOtherServices() async throws {
        let controls = RecordingExternalControls()
        let widget = RecordingWidgetLifecycle(startResult: false)
        let store = try makeStore(backend: MockAudioBackend())
        let lifecycle = AppLifecycleCoordinator(
            store: store,
            controls: controls,
            widgetBridge: widget
        )

        let report = await lifecycle.start()

        XCTAssertTrue(report.externalControlsStarted)
        XCTAssertTrue(report.observationStarted)
        XCTAssertFalse(report.widgetTransportStarted)
        _ = await lifecycle.stop()
    }

    func testApplySettingsIsIgnoredAfterTermination() async throws {
        let controls = RecordingExternalControls()
        let widget = RecordingWidgetLifecycle()
        let store = try makeStore(backend: MockAudioBackend())
        let lifecycle = AppLifecycleCoordinator(
            store: store,
            controls: controls,
            widgetBridge: widget
        )
        _ = await lifecycle.start()

        await lifecycle.applySettings()
        _ = await lifecycle.stop()
        await lifecycle.applySettings()

        XCTAssertEqual(controls.applyCount, 1)
        XCTAssertEqual(widget.flushCount, 1)
    }

    func testStopBeforeStartKeepsLifecycleTerminalWithoutStartingServices() async throws {
        let controls = RecordingExternalControls()
        let widget = RecordingWidgetLifecycle()
        let store = try makeStore(backend: MockAudioBackend())
        let lifecycle = AppLifecycleCoordinator(
            store: store,
            controls: controls,
            widgetBridge: widget
        )

        _ = await lifecycle.stop()
        let startReport = await lifecycle.start()

        XCTAssertFalse(startReport.observationStarted)
        XCTAssertFalse(startReport.externalControlsStarted)
        XCTAssertFalse(startReport.widgetTransportStarted)
        XCTAssertEqual(startReport.discoveryErrorDescription, "Lifecycle has already stopped.")
        XCTAssertEqual(controls.startCount, 0)
        XCTAssertEqual(widget.startCount, 0)
    }

    private func makeStore(backend: MockAudioBackend) throws -> AudioControlStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EQMacRep-Lifecycle-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try AudioControlStore(
            settingsStore: SettingsStore(settingsURL: url),
            backend: backend,
            permissionClient: LifecycleAudioPermissionClient()
        )
    }
}

final class AppURLRouteTests: XCTestCase {
    func testAcceptsOnlyExactOpenRoute() throws {
        XCTAssertEqual(AppURLRoute(try XCTUnwrap(URL(string: "eqmacrep://open"))), .openMainWindow)
        XCTAssertEqual(AppURLRoute(try XCTUnwrap(URL(string: "EQMACREP://OPEN"))), .openMainWindow)
    }

    func testRejectsNearMissAndUntrustedRoutes() throws {
        let rejected = [
            "https://open",
            "eqmacrep:open",
            "eqmacrep://other",
            "eqmacrep://open/",
            "eqmacrep://open/extra",
            "eqmacrep://open?source=widget",
            "eqmacrep://open#fragment",
            "eqmacrep://user@open",
            "eqmacrep://open:1234"
        ]

        for value in rejected {
            XCTAssertNil(AppURLRoute(try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testMainWindowIdentifierIsStableAndNotTitleBased() {
        XCTAssertEqual(AppWindowID.main.rawValue, "main")
        XCTAssertEqual(
            AppWindowID.main.nsIdentifier.rawValue,
            "com.michaeltrannhan.EQMacRep.window.main"
        )
    }
}

@MainActor
private final class LifecycleEventLog {
    var values: [String] = []
}

@MainActor
private final class RecordingExternalControls: ExternalControlsLifecycle {
    private let events: LifecycleEventLog?
    private(set) var startCount = 0
    private(set) var applyCount = 0
    private(set) var stopCount = 0

    init(events: LifecycleEventLog? = nil) {
        self.events = events
    }

    func start(store: AudioControlStore) {
        startCount += 1
        events?.values.append("controls.start")
    }

    func applySettings() {
        applyCount += 1
        events?.values.append("controls.apply")
    }

    func stop() {
        stopCount += 1
        events?.values.append("controls.stop")
    }
}

@MainActor
private final class RecordingWidgetLifecycle: WidgetBridgeLifecycle {
    private let events: LifecycleEventLog?
    private let startResult: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var flushCount = 0

    init(events: LifecycleEventLog? = nil, startResult: Bool = true) {
        self.events = events
        self.startResult = startResult
    }

    func start() async -> Bool {
        startCount += 1
        events?.values.append("widget.start")
        return startResult
    }

    func stop() async {
        stopCount += 1
        events?.values.append("widget.stop")
    }

    func flush() async {
        flushCount += 1
        events?.values.append("widget.flush")
    }
}

@MainActor
private struct LifecycleAudioPermissionClient: AudioCapturePermissionClient {
    func currentState() -> AudioCapturePermissionState {
        .init(screenCapture: .granted, audioUsageDescription: .present)
    }

    func requestScreenCaptureAccess() -> AudioCapturePermissionState { currentState() }
    func openPrivacySettings() {}
    func relaunchApp() async throws {}
}

private enum LifecycleTestError: LocalizedError {
    case discovery

    var errorDescription: String? { "Synthetic discovery failure" }
}
