import AppKit
import Foundation

@MainActor
protocol ExternalControlsLifecycle: AnyObject {
    func start(store: AudioControlStore)
    func applySettings()
    func stop()
}

@MainActor
protocol WidgetBridgeLifecycle: AnyObject {
    @discardableResult func start() async -> Bool
    func stop() async
    func flush() async
}

extension ExternalControlsCoordinator: ExternalControlsLifecycle {}
extension WidgetBridge: WidgetBridgeLifecycle {}

struct AppLifecycleStartReport: Equatable, Sendable {
    let discoveryErrorDescription: String?
    let observationStarted: Bool
    let externalControlsStarted: Bool
    let widgetTransportStarted: Bool
}

struct AppLifecycleStopReport: Equatable, Sendable {
    let externalControlsStopped: Bool
    let widgetTransportStopped: Bool
    let audio: AudioShutdownReport
}

/// The one scene-independent owner for application startup and teardown.
/// Individual services are attempted independently so one degraded facility
/// cannot prevent discovery, observers, controls, or widget transport from
/// starting or stopping.
@MainActor
final class AppLifecycleCoordinator {
    let store: AudioControlStore
    private let controls: any ExternalControlsLifecycle
    private let widgetBridge: any WidgetBridgeLifecycle

    private var startTask: Task<AppLifecycleStartReport, Never>?
    private var stopTask: Task<AppLifecycleStopReport, Never>?
    private var completedStartReport: AppLifecycleStartReport?
    private var completedStopReport: AppLifecycleStopReport?

    init(
        store: AudioControlStore,
        controls: any ExternalControlsLifecycle,
        widgetBridge: any WidgetBridgeLifecycle
    ) {
        self.store = store
        self.controls = controls
        self.widgetBridge = widgetBridge
    }

    func start() async -> AppLifecycleStartReport {
        if let completedStartReport { return completedStartReport }
        if let startTask { return await startTask.value }
        guard completedStopReport == nil else {
            return AppLifecycleStartReport(
                discoveryErrorDescription: "Lifecycle has already stopped.",
                observationStarted: false,
                externalControlsStarted: false,
                widgetTransportStarted: false
            )
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return AppLifecycleStartReport(
                    discoveryErrorDescription: "Lifecycle owner was released during startup.",
                    observationStarted: false,
                    externalControlsStarted: false,
                    widgetTransportStarted: false
                )
            }
            return await performStart()
        }
        startTask = task
        let report = await task.value
        startTask = nil
        completedStartReport = report
        return report
    }

    func applySettings() async {
        guard completedStopReport == nil else { return }
        controls.applySettings()
        await widgetBridge.flush()
    }

    func stop() async -> AppLifecycleStopReport {
        if let completedStopReport { return completedStopReport }
        if let stopTask { return await stopTask.value }
        if let startTask { _ = await startTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return AppLifecycleStopReport(
                    externalControlsStopped: false,
                    widgetTransportStopped: false,
                    audio: AudioShutdownReport(
                        editSessionErrorDescriptions: ["Lifecycle owner was released during shutdown."],
                        persistenceErrorDescription: nil,
                        engineReport: AudioEngineShutdownReport(
                            stoppedTopologyObservation: false,
                            stoppedOutputObservation: false,
                            stoppedMeterObservation: false,
                            teardownErrorDescription: nil
                        )
                    )
                )
            }
            return await performStop()
        }
        stopTask = task
        let report = await task.value
        stopTask = nil
        completedStopReport = report
        return report
    }

    private func performStart() async -> AppLifecycleStartReport {
        await store.waitUntilReady()
        store.refreshPermissionState()

        // Controls do not depend on discovery and should work before any scene
        // (especially the menu extra) is rendered or opened.
        controls.start(store: store)

        let discoveryError: String?
        do {
            try await store.refresh()
            discoveryError = nil
        } catch {
            discoveryError = error.localizedDescription
        }

        await store.startBackendObservation()
        // Publish only after the first discovery attempt, avoiding a transient
        // empty host snapshot during ordinary startup.
        let widgetStarted = await widgetBridge.start()

        return AppLifecycleStartReport(
            discoveryErrorDescription: discoveryError,
            observationStarted: true,
            externalControlsStarted: true,
            widgetTransportStarted: widgetStarted
        )
    }

    private func performStop() async -> AppLifecycleStopReport {
        controls.stop()
        await widgetBridge.stop()
        let audioReport = await store.shutdown()
        return AppLifecycleStopReport(
            externalControlsStopped: true,
            widgetTransportStopped: true,
            audio: audioReport
        )
    }
}

/// Bridges AppKit process lifecycle into the single async lifecycle owner.
@MainActor
final class AuralisApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var lifecycle: AppLifecycleCoordinator?
    private var terminationReplyPending = false

    func configure(lifecycle: AppLifecycleCoordinator) {
        self.lifecycle = lifecycle
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lifecycle else { return }
        Task { _ = await lifecycle.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lifecycle else { return .terminateNow }
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        Task {
            _ = await lifecycle.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
