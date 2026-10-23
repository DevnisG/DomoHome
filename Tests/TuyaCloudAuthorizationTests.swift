import Foundation
import XCTest

private final class CloudRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) { lock.lock(); defer { lock.unlock() }; paths.append(path) }
    var openingRequests: Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0.hasSuffix("/open-door") }.count }
}

private final class MockCloudURLProtocol: URLProtocol {
    static let recorder = CloudRequestRecorder()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.recorder.record(path)
        let object: [String: Any]
        if path == "/v1.0/token" {
            object = ["success": true, "result": ["access_token": "mock-token", "expire_time": 3600]]
        } else if path.hasSuffix("/empty-lock/status") {
            object = ["success": true, "result": []]
        } else if path.hasSuffix("/status") {
            object = ["success": true, "result": [["code": "residual_electricity", "value": 100], ["code": "unlock_app", "value": 1]]]
        } else if path.hasSuffix("/password-ticket") {
            object = ["success": true, "result": ["ticket_id": "mock-ticket"]]
        } else { object = ["success": true, "result": true] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TuyaCloudAuthorizationTests: XCTestCase {
    func testStatusResponseUsesActualPropertiesWithoutInferringDoorPosition() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudURLProtocol.self]
        let client = TuyaCloudClient(config: LockConfiguration(tuyaClientID: "mock-client", tuyaClientSecret: "mock-secret",
            tuyaAPIHost: "openapi.tuyaus.com", lockDeviceID: "status-lock", displayName: nil, group: nil),
            session: URLSession(configuration: configuration))
        let status = try await client.status()
        XCTAssertFalse(status.reportsDoorPosition)
        XCTAssertNil(status.doorIsOpen)
        XCTAssertEqual(status.batteryPercentage, 100)
    }

    func testEmptyStatusIsAnErrorInsteadOfSuccessfulUnknownState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudURLProtocol.self]
        let client = TuyaCloudClient(config: LockConfiguration(tuyaClientID: "mock-client", tuyaClientSecret: "mock-secret",
            tuyaAPIHost: "openapi.tuyaus.com", lockDeviceID: "empty-lock", displayName: nil, group: nil),
            session: URLSession(configuration: configuration))
        do {
            _ = try await client.status()
            XCTFail("An empty status response must fail")
        } catch is TuyaCloudAPIError { }
    }

    func testExistingCloudUnlockRevalidatesAfterTicketAndDoesNotSendWhenDenied() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCloudURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = TuyaCloudClient(config: LockConfiguration(tuyaClientID: "mock-client", tuyaClientSecret: "mock-secret",
            tuyaAPIHost: "openapi.tuyaus.com", lockDeviceID: "mock-lock", displayName: nil, group: nil), session: session)
        let before = MockCloudURLProtocol.recorder.openingRequests
        do {
            _ = try await client.unlock { false }
            XCTFail("Expired authorization must reject the unlock")
        } catch is TuyaCloudAPIError { }
        XCTAssertEqual(MockCloudURLProtocol.recorder.openingRequests, before)
        let accepted = try await client.unlock { true }
        XCTAssertTrue(accepted)
        XCTAssertEqual(MockCloudURLProtocol.recorder.openingRequests, before + 1)
    }
}

final class TuyaLockStatusTests: XCTestCase {
    func testActualLockWithoutPositionSensorReportsBatteryInsteadOfInventingDoorState() {
        let status = TuyaLockStatus(properties: ["residual_electricity": 100, "unlock_app": 1, "unlock_request": 0, "doorbell": true])
        XCTAssertNil(status.doorIsOpen)
        XCTAssertFalse(status.reportsDoorPosition)
        XCTAssertEqual(status.batteryPercentage, 100)
    }

    func testStandardDoorSensorAndUnknownValues() {
        XCTAssertEqual(TuyaLockStatus(properties: ["door_sensor": "open"]).doorIsOpen, true)
        XCTAssertEqual(TuyaLockStatus(properties: ["door_sensor": "closed"]).doorIsOpen, false)
        let status = TuyaLockStatus(properties: ["door_sensor": "unknown"])
        XCTAssertTrue(status.reportsDoorPosition)
        XCTAssertNil(status.doorIsOpen)
    }

    func testBooleanDoorStateDoesNotAcceptArbitraryIntegers() {
        XCTAssertEqual(TuyaLockStatus(properties: ["door_opened": true]).doorIsOpen, true)
        XCTAssertEqual(TuyaLockStatus(properties: ["door_opened": false]).doorIsOpen, false)
        XCTAssertNil(TuyaLockStatus(properties: ["door_opened": 7]).doorIsOpen)
    }

    func testMotorAndHistoricalUnlockEventsAreNotDoorPosition() {
        let status = TuyaLockStatus(properties: ["lock_motor_state": true, "unlock_app": 1, "unlock_password": 3])
        XCTAssertNil(status.doorIsOpen)
        XCTAssertFalse(status.reportsDoorPosition)
    }

    func testInvalidBatteryValuesAreIgnored() {
        for value: Any in [-1, 101, 2.5, true, "100"] {
            XCTAssertNil(TuyaLockStatus(properties: ["residual_electricity": value]).batteryPercentage)
        }
    }
}
