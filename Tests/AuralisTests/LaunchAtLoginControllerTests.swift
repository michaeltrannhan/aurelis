import ServiceManagement
import XCTest
@testable import Auralis

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testMapsServiceManagementStatus() {
        XCTAssertEqual(LoginItemStatus(.enabled), .enabled)
        XCTAssertEqual(LoginItemStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemStatus(.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemStatus(.notFound), .unavailable)
    }

    func testFirstRunDefaultsOnWhenMacOSCanRegister() {
        XCTAssertTrue(LoginItemStatus.notRegistered.defaultOnboardingEnabled)
        XCTAssertTrue(LoginItemStatus.enabled.defaultOnboardingEnabled)
        XCTAssertTrue(LoginItemStatus.requiresApproval.defaultOnboardingEnabled)
        XCTAssertFalse(LoginItemStatus.unavailable.defaultOnboardingEnabled)
    }

    func testEnablingFromNotRegisteredRegistersOnce() {
        let client = StubLoginItemClient(status: .notRegistered)
        let controller = LaunchAtLoginController(client: client)

        controller.setEnabled(true)

        XCTAssertEqual(client.registerCount, 1)
        XCTAssertEqual(client.unregisterCount, 0)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testEnablingWhenAlreadyEnabledOrPendingApprovalDoesNotReregister() {
        let enabledClient = StubLoginItemClient(status: .enabled)
        let enabledController = LaunchAtLoginController(client: enabledClient)
        enabledController.setEnabled(true)
        XCTAssertEqual(enabledClient.registerCount, 0)
        XCTAssertEqual(enabledClient.openCount, 0)

        let pendingClient = StubLoginItemClient(status: .requiresApproval)
        let pendingController = LaunchAtLoginController(client: pendingClient)
        pendingController.setEnabled(true)
        XCTAssertEqual(pendingClient.registerCount, 0)
        XCTAssertEqual(pendingClient.openCount, 0)
        XCTAssertTrue(pendingController.isEnabled)
    }

    func testSettingsToggleOpensLoginItemsWhenApprovalIsRequired() {
        let pendingClient = StubLoginItemClient(status: .requiresApproval)
        let pendingController = LaunchAtLoginController(client: pendingClient)
        pendingController.setEnabled(true, opensLoginItemsIfNeeded: true)
        XCTAssertEqual(pendingClient.registerCount, 0)
        XCTAssertEqual(pendingClient.openCount, 1)

        let registeringClient = StubLoginItemClient(status: .notRegistered)
        registeringClient.statusAfterRegister = .requiresApproval
        let registeringController = LaunchAtLoginController(client: registeringClient)
        registeringController.setEnabled(true, opensLoginItemsIfNeeded: true)
        XCTAssertEqual(registeringClient.registerCount, 1)
        XCTAssertEqual(registeringClient.openCount, 1)
        XCTAssertEqual(registeringController.status, .requiresApproval)
    }

    func testSettingsToggleDoesNotOpenLoginItemsWhenAlreadyEnabled() {
        let client = StubLoginItemClient(status: .enabled)
        let controller = LaunchAtLoginController(client: client)

        controller.setEnabled(true, opensLoginItemsIfNeeded: true)

        XCTAssertEqual(client.openCount, 0)
    }

    func testEnablingWhenUnavailableSurfacesErrorWithoutCallingRegister() {
        let client = StubLoginItemClient(status: .unavailable)
        let controller = LaunchAtLoginController(client: client)

        controller.setEnabled(true)

        XCTAssertEqual(client.registerCount, 0)
        XCTAssertEqual(controller.status, .unavailable)
        XCTAssertEqual(controller.lastErrorMessage, LoginItemError.unavailable.errorDescription)
    }

    func testDisablingUnregistersEnabledAndPendingItems() {
        let enabledClient = StubLoginItemClient(status: .enabled)
        let enabledController = LaunchAtLoginController(client: enabledClient)
        enabledController.setEnabled(false)
        XCTAssertEqual(enabledClient.unregisterCount, 1)
        XCTAssertEqual(enabledController.status, .notRegistered)

        let pendingClient = StubLoginItemClient(status: .requiresApproval)
        let pendingController = LaunchAtLoginController(client: pendingClient)
        pendingController.setEnabled(false)
        XCTAssertEqual(pendingClient.unregisterCount, 1)
        XCTAssertEqual(pendingController.status, .notRegistered)
    }

    func testDisablingWhenNotRegisteredIsANoOp() {
        let client = StubLoginItemClient(status: .notRegistered)
        let controller = LaunchAtLoginController(client: client)

        controller.setEnabled(false)

        XCTAssertEqual(client.unregisterCount, 0)
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testRegisterFailureIsPublishedAndStatusRefreshed() {
        let client = StubLoginItemClient(status: .notRegistered)
        client.registerError = StubLoginItemFailure("Synthetic register failure")
        let controller = LaunchAtLoginController(client: client)

        controller.setEnabled(true)

        XCTAssertEqual(client.registerCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(controller.lastErrorMessage, "Synthetic register failure")
    }

    func testOnboardingPreferenceSkipsUnavailableBundles() {
        let client = StubLoginItemClient(status: .unavailable)
        let controller = LaunchAtLoginController(client: client)

        controller.applyOnboardingPreference(true)

        XCTAssertEqual(client.registerCount, 0)
        XCTAssertNil(controller.lastErrorMessage)
    }

    func testOnboardingPreferenceRegistersWhenRequested() {
        let client = StubLoginItemClient(status: .notRegistered)
        let controller = LaunchAtLoginController(client: client)

        controller.applyOnboardingPreference(true)

        XCTAssertEqual(client.registerCount, 1)
        XCTAssertEqual(controller.status, .enabled)
    }

    func testOnboardingPreferenceDoesNotOpenLoginItems() {
        let client = StubLoginItemClient(status: .notRegistered)
        client.statusAfterRegister = .requiresApproval
        let controller = LaunchAtLoginController(client: client)

        controller.applyOnboardingPreference(true)

        XCTAssertEqual(client.registerCount, 1)
        XCTAssertEqual(client.openCount, 0)
        XCTAssertEqual(controller.status, .requiresApproval)
    }

    func testOpenLoginItemsSettingsFailureIsVisible() {
        let client = StubLoginItemClient(status: .requiresApproval)
        client.openResult = false
        let controller = LaunchAtLoginController(client: client)

        controller.openLoginItemsSettings()

        XCTAssertEqual(client.openCount, 1)
        XCTAssertEqual(controller.lastErrorMessage, "Couldn’t open Login Items settings.")
    }
}

@MainActor
private final class StubLoginItemClient: LoginItemClient {
    var status: LoginItemStatus
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: Error?
    var unregisterError: Error?
    var openResult = true
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openCount = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func currentStatus() -> LoginItemStatus { status }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openLoginItemsSettings() -> Bool {
        openCount += 1
        return openResult
    }
}

private struct StubLoginItemFailure: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
