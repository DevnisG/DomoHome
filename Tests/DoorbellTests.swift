import Foundation
import XCTest

final class TestDoorbellClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var uptime: TimeInterval = 100

    func wall() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func monotonic() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return uptime }
    func advance(_ seconds: TimeInterval, wallOnly: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(seconds)
        if !wallOnly { uptime += seconds }
    }
    var clock: DoorbellClock { DoorbellClock(wall: { self.wall() }, monotonic: { self.monotonic() }) }
}

final class DoorbellTests: XCTestCase {
    private var clock: TestDoorbellClock!
    private var coordinator: TuyaDoorbellCoordinator!

    override func setUp() async throws {
        clock = TestDoorbellClock()
        var settings = TuyaDoorbellSettings()
        settings.enabled = true
        settings.environment = .test
        settings.maxEventAge = 10
        settings.maxClockSkew = 2
        coordinator = TuyaDoorbellCoordinator(deviceID: "fixture-lock", settings: settings, clock: clock.clock)
        await coordinator.receive(TuyaMessage(type: "connection", state: "connected", environment: "TEST"))
        clock.advance(0.1)
    }

    private func event(_ dp: Int, _ value: TuyaDPValue, age: TimeInterval = 0, device: String = "fixture-lock", id: String = UUID().uuidString) -> TuyaMessage {
        let timestamp = clock.wall().addingTimeInterval(-age)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let code = [19: "doorbell", 9: "unlock_request", 15: "unlock_app", 50: "remote_no_dp_key"][dp]
        return TuyaMessage(deviceId: device, dataId: id, messageId: id, dpId: dp, code: code, value: value,
                           eventTimeMs: Int64(timestamp.timeIntervalSince1970 * 1000), publishedAt: formatter.string(from: clock.wall()))
    }

    func testDoorbellNeverAuthorizesAndForeignDeviceIsIgnored() async {
        let foreign = await coordinator.receive(event(19, .boolean(true), device: "other"))
        XCTAssertNil(foreign)
        let notification = await coordinator.receive(event(19, .boolean(true)))
        XCTAssertNotNil(notification)
        let authorization = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(authorization)
        let state = await coordinator.current()
        XCTAssertEqual(state.phase, .ringing)
    }

    func testDuplicateAndRepeatedDoorbellsNotifyOnce() async {
        let first = event(19, .boolean(true))
        let notification = await coordinator.receive(first)
        XCTAssertNotNil(notification)
        let duplicate = await coordinator.receive(first)
        XCTAssertNil(duplicate)
        var redelivery = first
        redelivery.messageId = "another-transport-id"
        let duplicateData = await coordinator.receive(redelivery)
        XCTAssertNil(duplicateData)
        clock.advance(1)
        let repeated = await coordinator.receive(event(19, .string("true")))
        XCTAssertNil(repeated)
    }

    func testWindowWithoutDoorbellAndDecrementsDoNotNotifyOrExtend() async {
        let notification = await coordinator.receive(event(9, .integer(60)))
        XCTAssertNil(notification)
        let initial = await coordinator.current()
        XCTAssertEqual(initial.phase, .available)
        XCTAssertTrue((57...58).contains(initial.remainingSeconds))
        clock.advance(2)
        await coordinator.receive(event(9, .string("58")))
        let next = await coordinator.current()
        XCTAssertEqual(initial.sessionID, next.sessionID)
        XCTAssertLessThanOrEqual(next.remainingSeconds, initial.remainingSeconds - 2)
        clock.advance(2)
        await coordinator.receive(event(9, .integer(120)))
        let increased = await coordinator.current()
        XCTAssertLessThanOrEqual(increased.remainingSeconds, next.remainingSeconds - 2)
    }

    func testZeroClosesImmediatelyWithoutClaimingExpiration() async {
        await coordinator.receive(event(9, .integer(60)))
        clock.advance(1)
        await coordinator.receive(event(9, .integer(0)))
        let state = await coordinator.current()
        XCTAssertEqual(state.phase, .closed)
        let authorization = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(authorization)
    }

    func testOldFutureAndOldPublicationEventsAreRejected() async {
        for age in [90.0, -10.0] {
            let notification = await coordinator.receive(event(19, .boolean(true), age: age))
            XCTAssertNil(notification)
            await coordinator.receive(event(9, .integer(60), age: age))
        }
        var oldPublication = event(9, .integer(60))
        oldPublication.publishedAt = ISO8601DateFormatter().string(from: clock.wall().addingTimeInterval(-90))
        await coordinator.receive(oldPublication)
        let state = await coordinator.current()
        XCTAssertFalse(state.canUnlock)
    }

    func testSimultaneousIntentsConsumeOneAttemptAndFailureDoesNotRetry() async {
        await coordinator.receive(event(9, .integer(60)))
        let currentCoordinator = coordinator!
        let permits = await withTaskGroup(of: UUID?.self, returning: [UUID].self) { group in
            for _ in 0..<20 { group.addTask { await currentCoordinator.reserveUnlock(sessionAvailable: true) } }
            var results: [UUID] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        XCTAssertEqual(permits.count, 1)
        await coordinator.completeUnlock(sessionID: permits[0], accepted: nil)
        clock.advance(1)
        await coordinator.receive(event(9, .integer(58)))
        let retry = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(retry)
        let state = await coordinator.current()
        XCTAssertEqual(state.phase, .unknown)
    }

    func testRevalidationAfterTicketAndMacLockFailsClosed() async throws {
        await coordinator.receive(event(9, .integer(60)))
        let locked = await coordinator.reserveUnlock(sessionAvailable: false)
        XCTAssertNil(locked)
        let reserved = await coordinator.reserveUnlock(sessionAvailable: true)
        let id = try XCTUnwrap(reserved)
        let available = await coordinator.authorizeSend(sessionID: id, sessionAvailable: true)
        XCTAssertTrue(available)
        let unavailable = await coordinator.authorizeSend(sessionID: id, sessionAvailable: false)
        XCTAssertFalse(unavailable)
        clock.advance(1)
        await coordinator.receive(event(9, .integer(0)))
        let closed = await coordinator.authorizeSend(sessionID: id, sessionAvailable: true)
        XCTAssertFalse(closed)
    }

    func testMonotonicAndWallClockExpiration() async {
        await coordinator.receive(event(9, .integer(5)))
        clock.advance(4)
        let state = await coordinator.current()
        XCTAssertEqual(state.phase, .expired)
        let permit = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(permit)
    }

    func testClockJumpFailsClosed() async {
        await coordinator.receive(event(9, .integer(60)))
        clock.advance(120, wallOnly: true)
        let permit = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(permit)
    }

    func testOutOfOrderPositiveCannotResurrectClosedWindow() async {
        let positive = event(9, .integer(60))
        clock.advance(1)
        await coordinator.receive(event(9, .integer(0)))
        await coordinator.receive(positive)
        let state = await coordinator.current()
        XCTAssertFalse(state.canUnlock)
    }

    func testDisconnectAndBacklogDoNotRestoreAuthorization() async {
        await coordinator.receive(event(9, .integer(60)))
        clock.advance(1)
        let backlog = event(9, .integer(58))
        clock.advance(1)
        await coordinator.invalidate()
        await coordinator.receive(TuyaMessage(type: "connection", state: "connected", environment: "TEST"))
        await coordinator.receive(backlog)
        let state = await coordinator.current()
        XCTAssertFalse(state.canUnlock)
    }

    func testUncorrelatedUnlockReportDoesNotClaimSuccess() async {
        await coordinator.receive(event(15, .integer(1)))
        let state = await coordinator.current()
        XCTAssertEqual(state.phase, .idle)
    }

    func testReportCorrelatesAfterZeroButNeverClaimsPhysicalState() async throws {
        await coordinator.receive(event(9, .integer(60)))
        let reserved = await coordinator.reserveUnlock(sessionAvailable: true)
        let permit = try XCTUnwrap(reserved)
        await coordinator.completeUnlock(sessionID: permit, accepted: true)
        clock.advance(1)
        await coordinator.receive(event(9, .integer(0)))
        clock.advance(1)
        await coordinator.receive(event(15, .integer(1)))
        let state = await coordinator.current()
        XCTAssertEqual(state.phase, .reported)
        XCTAssertFalse(state.canUnlock)
    }

    func testNotificationFromPreviousSessionIsRejectedAndIgnoreClosesWindow() async throws {
        await coordinator.receive(event(9, .integer(60)))
        let original = await coordinator.current()
        await coordinator.ignore(sessionID: try XCTUnwrap(original.sessionID))
        let ignored = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(ignored)
        clock.advance(1)
        await coordinator.receive(event(19, .boolean(true)))
        clock.advance(1)
        await coordinator.receive(event(9, .integer(60)))
        let stale = await coordinator.reserveUnlock(sessionID: original.sessionID, sessionAvailable: true)
        XCTAssertNil(stale)
    }

    func testInvalidContractCodeAndBooleanCountdownAreIgnored() async throws {
        var invalid = event(9, .integer(60))
        invalid.code = "doorbell"
        await coordinator.receive(invalid)
        invalid = event(9, .integer(60))
        invalid.schemaVersion = 2
        await coordinator.receive(invalid)
        await coordinator.receive(event(9, .boolean(true)))
        let state = await coordinator.current()
        XCTAssertFalse(state.canUnlock)
        for source in ["true", "60", "\"60\""] {
            XCTAssertNoThrow(try JSONDecoder().decode(TuyaDPValue.self, from: Data(source.utf8)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(TuyaMessage.self, from: Data("{}".utf8)))
    }

    func testRestartDoesNotPersistWindow() async {
        await coordinator.receive(event(9, .integer(60)))
        let replacement = TuyaDoorbellCoordinator(deviceID: "fixture-lock", settings: TuyaDoorbellSettings(), clock: clock.clock)
        let state = await replacement.current()
        XCTAssertFalse(state.canUnlock)
    }

    func testSyntheticTwentyRecordCycleAndLateReport() async throws {
        struct Record: Decodable {
            let dpId: Int
            let code: String
            let value: TuyaDPValue
            let offsetSeconds: Double
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/doorbell-cycle.json")
        let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
        XCTAssertEqual(records.count, 20)
        var previousOffset = 0.0
        var notifications = 0
        var permit: UUID?
        for record in records {
            clock.advance(record.offsetSeconds - previousOffset)
            previousOffset = record.offsetSeconds
            if await coordinator.receive(event(record.dpId, record.value)) != nil { notifications += 1 }
            if record.dpId == 9, record.value == .integer(45) {
                permit = await coordinator.reserveUnlock(sessionAvailable: true)
                if let permit { await coordinator.completeUnlock(sessionID: permit, accepted: true) }
            }
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertNotNil(permit)
        let state = await coordinator.current()
        XCTAssertFalse(state.canUnlock)
        XCTAssertEqual(state.phase, .closed)
    }

    func testMultiplePropertiesWithSameMessageIDAreNotDropped() async {
        let id = UUID().uuidString
        let notification = await coordinator.receive(event(19, .boolean(true), id: id))
        await coordinator.receive(event(9, .integer(60), id: id))
        XCTAssertNotNil(notification)
        let state = await coordinator.current()
        XCTAssertTrue(state.canUnlock)
    }

    func testSendPermitCannotBeUsedTwice() async throws {
        await coordinator.receive(event(9, .integer(60)))
        let reserved = await coordinator.reserveUnlock(sessionAvailable: true)
        let id = try XCTUnwrap(reserved)
        let first = await coordinator.authorizeSend(sessionID: id, sessionAvailable: true)
        let second = await coordinator.authorizeSend(sessionID: id, sessionAvailable: true)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testDecodingFailureInvalidatesExistingWindow() async {
        await coordinator.receive(event(9, .integer(60)))
        await coordinator.receive(TuyaMessage(type: "diagnostic", state: "DecodingFailure"))
        let permit = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(permit)
    }

    func testDisabledServiceAndWrongEnvironmentFailClosed() async {
        var settings = TuyaDoorbellSettings()
        settings.enabled = false
        let disabled = TuyaDoorbellCoordinator(deviceID: "fixture-lock", settings: settings, clock: clock.clock)
        await disabled.receive(TuyaMessage(type: "connection", state: "connected", environment: "TEST"))
        await disabled.receive(event(9, .integer(60)))
        let disabledPermit = await disabled.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(disabledPermit)
        await coordinator.receive(TuyaMessage(type: "connection", state: "connected", environment: "PROD"))
        await coordinator.receive(event(9, .integer(60)))
        let wrongEnvironmentPermit = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(wrongEnvironmentPermit)
    }

    func testNotificationPreferenceDoesNotBypassAuthorization() async {
        var settings = TuyaDoorbellSettings()
        settings.enabled = true
        settings.notificationsEnabled = false
        settings.environment = .test
        let silent = TuyaDoorbellCoordinator(deviceID: "fixture-lock", settings: settings, clock: clock.clock)
        await silent.receive(TuyaMessage(type: "connection", state: "connected", environment: "TEST"))
        clock.advance(1)
        await silent.receive(event(19, .boolean(true)))
        let noWindow = await silent.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(noWindow)
        await silent.receive(event(9, .integer(60)))
        let validWindow = await silent.reserveUnlock(sessionAvailable: true)
        XCTAssertNotNil(validWindow)
    }

    func testLatencySamplesAreBoundedAndNoWindowIsPersisted() {
        var metrics = DoorbellMetrics()
        for index in 0..<300 {
            let event = Date(timeIntervalSince1970: Double(index))
            metrics.recordEvent(event: event, published: event.addingTimeInterval(2), received: event.addingTimeInterval(3))
            metrics.recordNotification(event: event, delivered: event.addingTimeInterval(4))
        }
        XCTAssertEqual(metrics.eventToPublish.count, 256)
        XCTAssertEqual(metrics.eventToNotification.count, 256)
        XCTAssertTrue(DoorbellMetrics.percentiles(metrics.eventToNotification).contains("4.00"))
        XCTAssertEqual(DoorbellMetrics.percentiles([]), "—")
    }

    func testIgnoreIsNotReopenedByCountdownOrRepeatedRing() async throws {
        await coordinator.receive(event(9, .integer(60)))
        let snapshot = await coordinator.current()
        await coordinator.ignore(sessionID: try XCTUnwrap(snapshot.sessionID))
        clock.advance(1)
        await coordinator.receive(event(9, .integer(58)))
        let repeatedRing = await coordinator.receive(event(19, .boolean(true)))
        XCTAssertNil(repeatedRing)
        let permit = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(permit)
    }

    func testReconnectCannotResetAnAlreadyConsumedRequest() async throws {
        await coordinator.receive(event(9, .integer(60)))
        let reserved = await coordinator.reserveUnlock(sessionAvailable: true)
        let id = try XCTUnwrap(reserved)
        await coordinator.completeUnlock(sessionID: id, accepted: true)
        await coordinator.invalidate()
        clock.advance(1)
        await coordinator.receive(TuyaMessage(type: "connection", state: "connected", environment: "TEST"))
        await coordinator.receive(event(9, .integer(58)))
        let repeated = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNil(repeated)
        clock.advance(1)
        await coordinator.receive(event(9, .integer(0)))
        clock.advance(1)
        await coordinator.receive(event(9, .integer(60)))
        let nextRequest = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNotNil(nextRequest)
        XCTAssertNotEqual(nextRequest, id)
    }

    func testDoorbellWithoutWindowEventuallyExpiresAndAllowsNewCall() async {
        let first = await coordinator.receive(event(19, .boolean(true)))
        clock.advance(121)
        let expired = await coordinator.current()
        XCTAssertEqual(expired.phase, .expired)
        let next = await coordinator.receive(event(19, .boolean(true)))
        XCTAssertNotNil(next)
        XCTAssertNotEqual(first, next)
    }

    func testNewWindowAfterConsumedRequestExpiresWithoutZero() async throws {
        await coordinator.receive(event(9, .integer(60)))
        let first = await coordinator.reserveUnlock(sessionAvailable: true)
        await coordinator.completeUnlock(sessionID: try XCTUnwrap(first), accepted: true)
        clock.advance(61)
        await coordinator.receive(event(9, .integer(60)))
        let next = await coordinator.reserveUnlock(sessionAvailable: true)
        XCTAssertNotNil(next)
        XCTAssertNotEqual(first, next)
    }

    func testMockStreamStopsCleanly() async {
        let mock = MockTuyaMessageStream()
        mock.send(event(19, .boolean(true)))
        mock.stop()
        var count = 0
        for await _ in mock.messages() { count += 1 }
        XCTAssertEqual(count, 1)
    }
}

@MainActor
private final class RecordingDoorbellPresenter: DoorbellAlertPresenting {
    var presented: [DoorbellSnapshot] = []
    var updated: [DoorbellSnapshot] = []
    var dismissals = 0
    var presentationSucceeds = true

    func present(_ snapshot: DoorbellSnapshot) -> Bool {
        presented.append(snapshot)
        return presentationSucceeds
    }
    func update(_ snapshot: DoorbellSnapshot) { updated.append(snapshot) }
    func dismiss() { dismissals += 1 }
}

final class DoorbellDeliveryTests: XCTestCase {
    @MainActor
    func testRingAlwaysAttemptsPanelBeforeConsideringNativeFallback() {
        let presenter = RecordingDoorbellPresenter()
        let delivery = DoorbellAlertDelivery(presenter: presenter)
        let snapshot = DoorbellSnapshot(phase: .ringing, sessionID: UUID())
        let needsFallback = delivery.receiveCall(snapshot, enabled: true)
        XCTAssertEqual(presenter.presented, [snapshot])
        XCTAssertFalse(needsFallback)
        XCTAssertFalse(snapshot.canUnlock)
    }

    @MainActor
    func testNativeFallbackOnlyWhenPanelPresentationFails() {
        let presenter = RecordingDoorbellPresenter()
        presenter.presentationSucceeds = false
        let delivery = DoorbellAlertDelivery(presenter: presenter)
        XCTAssertTrue(delivery.receiveCall(DoorbellSnapshot(phase: .ringing, sessionID: UUID()), enabled: true))
        XCTAssertEqual(presenter.presented.count, 1)
    }

    @MainActor
    func testCountdownUpdatesExistingPanelAndZeroDismissesIt() {
        let presenter = RecordingDoorbellPresenter()
        let delivery = DoorbellAlertDelivery(presenter: presenter)
        let id = UUID()
        _ = delivery.receiveCall(DoorbellSnapshot(phase: .ringing, sessionID: id), enabled: true)
        delivery.update(DoorbellSnapshot(phase: .available, sessionID: id, remainingSeconds: 48))
        XCTAssertEqual(presenter.updated.last?.remainingSeconds, 48)
        XCTAssertEqual(presenter.presented.count, 1)
        delivery.update(DoorbellSnapshot(phase: .closed, sessionID: id))
        XCTAssertEqual(presenter.dismissals, 1)
    }

    @MainActor
    func testDuplicateRingDoesNotCreateAnotherPanel() {
        let presenter = RecordingDoorbellPresenter()
        let delivery = DoorbellAlertDelivery(presenter: presenter)
        let snapshot = DoorbellSnapshot(phase: .ringing, sessionID: UUID())
        _ = delivery.receiveCall(snapshot, enabled: true)
        _ = delivery.receiveCall(snapshot, enabled: true)
        XCTAssertEqual(presenter.presented.count, 1)
    }

    @MainActor
    func testCountdownWithoutRingCannotCreatePanel() {
        let presenter = RecordingDoorbellPresenter()
        let delivery = DoorbellAlertDelivery(presenter: presenter)
        delivery.update(DoorbellSnapshot(phase: .available, sessionID: UUID(), remainingSeconds: 60))
        XCTAssertTrue(presenter.presented.isEmpty)
        XCTAssertTrue(presenter.updated.isEmpty)
    }

    @MainActor
    func testDisabledAlertsAndExpiredRequestsNeverPresent() {
        let presenter = RecordingDoorbellPresenter()
        let delivery = DoorbellAlertDelivery(presenter: presenter)
        _ = delivery.receiveCall(DoorbellSnapshot(phase: .ringing, sessionID: UUID()), enabled: false)
        _ = delivery.receiveCall(DoorbellSnapshot(phase: .expired, sessionID: UUID()), enabled: true)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func testListeningPreferenceSurvivesRestartWithoutChangingNotificationChoice() {
        let suite = "org.domohome.tests.listening." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = TuyaDoorbellSettings(defaults: defaults, bundleEnvironment: "TEST")
        settings.enabled = true
        settings.notificationsEnabled = true
        settings.save(defaults: defaults)
        settings.enabled = false
        settings.save(defaults: defaults)
        let restored = TuyaDoorbellSettings(defaults: defaults, bundleEnvironment: "PROD")
        XCTAssertFalse(restored.enabled)
        XCTAssertTrue(restored.notificationsEnabled)
        XCTAssertEqual(restored.environment, .test)
        settings.enabled = true
        settings.save(defaults: defaults)
        XCTAssertTrue(TuyaDoorbellSettings(defaults: defaults).enabled)
    }

    func testReleaseEnvironmentAndExplicitTestOverride() {
        let suite = "org.domohome.tests.environment." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TuyaDoorbellSettings(defaults: defaults, bundleEnvironment: "PROD").environment, .production)
        XCTAssertEqual(TuyaDoorbellSettings(defaults: defaults, bundleEnvironment: "TEST").environment, .test)
        defaults.set("TEST", forKey: "tuyaDoorbellEnvironment")
        XCTAssertEqual(TuyaDoorbellSettings(defaults: defaults, bundleEnvironment: "PROD").environment, .test)
    }
}

final class MacSessionAvailabilityTests: XCTestCase {
    @MainActor
    func testExplicitOpenOnUnlockedConsoleNeedsNoOwnerAuthentication() {
        let session = MacSessionAvailability(sessionCheck: { true }, uptime: { 100 })
        XCTAssertFalse(session.isAvailable())
        XCTAssertTrue(session.beginInteraction())
        XCTAssertTrue(session.isAvailable())
    }

    @MainActor
    func testLockedConsoleRejectsOpenAndRechecksBeforeSending() {
        var unlocked = false
        let session = MacSessionAvailability(sessionCheck: { unlocked }, uptime: { 100 })
        XCTAssertFalse(session.beginInteraction())
        unlocked = true
        XCTAssertTrue(session.beginInteraction())
        unlocked = false
        XCTAssertFalse(session.isAvailable())
    }

    @MainActor
    func testSleepOrSessionChangeInvalidatesPendingInteraction() {
        let session = MacSessionAvailability(sessionCheck: { true }, uptime: { 100 })
        var invalidated = false
        session.onUnavailable = { invalidated = true }
        XCTAssertTrue(session.beginInteraction())
        session.invalidate()
        XCTAssertTrue(invalidated)
        XCTAssertFalse(session.isAvailable())
    }

    @MainActor
    func testDelayedCommandCannotReuseExpiredInteraction() {
        var uptime: TimeInterval = 100
        let session = MacSessionAvailability(sessionCheck: { true }, uptime: { uptime })
        XCTAssertTrue(session.beginInteraction())
        uptime = 130
        XCTAssertFalse(session.isAvailable())
    }
}
