import Foundation
import ServiceManagement
import XCTest

@MainActor
private final class MockLoginItemService: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var registrations = 0
    var removals = 0
    var settingsOpened = 0
    var registrationFails = false

    func register() throws {
        registrations += 1
        if registrationFails { throw NSError(domain: "fixture", code: 1) }
        status = registrationStatus
    }
    func unregister() async throws { removals += 1; status = .notRegistered }
    func openSettings() { settingsOpened += 1 }
}

final class LoginItemManagerTests: XCTestCase {
    @MainActor
    func testTemporaryCopyCannotBecomeLoginItem() async {
        let service = MockLoginItemService()
        let manager = LoginItemManager(service: service, bundleURL: URL(fileURLWithPath: "/private/tmp/preview/DomoHome.app"))
        await manager.setEnabled(true)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testInstalledCopyRegistersAndUnregisters() async {
        let service = MockLoginItemService()
        let manager = LoginItemManager(service: service, bundleURL: URL(fileURLWithPath: "/Applications/DomoHome.app"))
        await manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(service.registrations, 1)
        await manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(service.removals, 1)
        XCTAssertFalse(manager.isUpdating)
    }

    @MainActor
    func testApprovalIsNotDisplayedAsEnabledAndCanOpenSettings() async {
        let service = MockLoginItemService()
        service.registrationStatus = .requiresApproval
        let manager = LoginItemManager(service: service, bundleURL: URL(fileURLWithPath: "/Applications/DomoHome.app"))
        await manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertTrue(manager.requiresApproval)
        XCTAssertNil(manager.errorMessage)
        await manager.setEnabled(true)
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(service.settingsOpened, 1)
        service.status = .enabled
        manager.refreshStatus()
        XCTAssertTrue(manager.isEnabled)
        XCTAssertFalse(manager.requiresApproval)
    }

    @MainActor
    func testAlreadyEnabledRegistrationIsIdempotent() async {
        let service = MockLoginItemService()
        service.status = .enabled
        let manager = LoginItemManager(service: service, bundleURL: URL(fileURLWithPath: "/Applications/DomoHome.app"))
        await manager.setEnabled(true)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testRegistrationFailureRestoresActualState() async {
        let service = MockLoginItemService()
        service.registrationFails = true
        let manager = LoginItemManager(service: service, bundleURL: URL(fileURLWithPath: "/Applications/DomoHome.app"))
        await manager.setEnabled(true)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.isUpdating)
    }

    @MainActor
    func testExternalDisableIsReflectedOnRefresh() {
        let service = MockLoginItemService()
        service.status = .enabled
        let manager = LoginItemManager(service: service)
        service.status = .notRegistered
        manager.refreshStatus()
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testUserApplicationsIsAcceptedAndRepositoryBuildIsRejected() {
        let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DomoHome.app")
        XCTAssertTrue(LoginItemManager.isInstalled(app))
        XCTAssertFalse(LoginItemManager.isInstalled(URL(fileURLWithPath: "/Users/example/Dev/DomoHome/build/DomoHome.app")))
    }
}
