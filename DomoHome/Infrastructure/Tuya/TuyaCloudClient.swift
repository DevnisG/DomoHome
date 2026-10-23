import Foundation
import CryptoKit
import CoreFoundation

struct TuyaCloudAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { L10n.text(message) }
}

struct TuyaLockStatus: Sendable {
    let doorIsOpen: Bool?
    let reportsDoorPosition: Bool
    let batteryPercentage: Int?

    init(properties: [String: Any]) {
        let keys = ["door_open", "door_opened", "door_state", "door_sensor_state", "door_sensor", "closed_opened"]
        reportsDoorPosition = keys.contains { properties[$0] != nil }
        doorIsOpen = keys.compactMap { key -> Bool? in
            guard let value = properties[key] else { return nil }
            if let text = value as? String {
                switch text.lowercased() {
                case "open", "opened", "true", "1": return true
                case "closed", "false", "0": return false
                default: return nil
                }
            }
            if let number = value as? NSNumber {
                if number.doubleValue == 0 { return false }
                if number.doubleValue == 1 { return true }
            }
            return nil
        }.first
        batteryPercentage = ["residual_electricity", "battery_percentage"].compactMap { key -> Int? in
            guard let value = properties[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  (0...100).contains(value.doubleValue),
                  value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.intValue
        }.first
    }
}

actor TuyaCloudClient {
    private let config: LockConfiguration
    private let session: URLSession
    private var accessToken = ""
    private var tokenExpiry = Date.distantPast

    init(config: LockConfiguration, session: URLSession? = nil) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration, delegate: CloudRedirectPolicy(), delegateQueue: nil)
    }

    func unlock(authorize: @Sendable () async -> Bool) async throws -> Bool {
        try await ensureToken()
        let ticketResponse = try await request(
            method: "POST",
            path: "/v1.0/devices/\(config.lockDeviceID)/door-lock/password-ticket",
            bodyObject: nil
        )
        guard let result = ticketResponse["result"] as? [String: Any],
              let ticket = result["ticket_id"] as? String,
              !ticket.isEmpty else {
            throw TuyaCloudAPIError(message: "Tuya no devolvió ticket_id para la cerradura.")
        }

        try Task.checkCancellation()
        guard await authorize() else {
            throw TuyaCloudAPIError(message: "La solicitud venció o la sesión de macOS no está disponible.")
        }
        let response = try await request(
            method: "POST",
            path: "/v1.0/devices/\(config.lockDeviceID)/door-lock/password-free/open-door",
            bodyObject: ["ticket_id": ticket]
        )
        return (response["result"] as? Bool) ?? false
    }

    func status() async throws -> TuyaLockStatus {
        try await ensureToken()
        let response = try await request(
            method: "GET",
            path: "/v1.0/iot-03/devices/\(config.lockDeviceID)/status",
            bodyObject: nil
        )

        var state: [String: Any] = [:]
        guard let list = response["result"] as? [[String: Any]], !list.isEmpty else {
            throw TuyaCloudAPIError(message: "Tuya no devolvió el estado de la cerradura.")
        }
        for item in list {
            if let code = item["code"] as? String, let value = item["value"] {
                state[code] = value
            }
        }
        return TuyaLockStatus(properties: state)
    }

    private func ensureToken() async throws {
        if !accessToken.isEmpty, tokenExpiry.timeIntervalSinceNow > 60 { return }

        let response = try await rawRequest(
            method: "GET",
            path: "/v1.0/token?grant_type=1",
            body: Data(),
            useToken: false
        )
        guard let result = response["result"] as? [String: Any],
              let token = result["access_token"] as? String,
              !token.isEmpty else {
            throw TuyaCloudAPIError(message: "No se pudo obtener el access_token de Tuya.")
        }
        accessToken = token

        let expires: TimeInterval
        if let value = result["expire_time"] as? Double {
            expires = value
        } else if let value = result["expire_time"] as? NSNumber {
            expires = value.doubleValue
        } else {
            expires = 3600
        }
        tokenExpiry = Date().addingTimeInterval(expires)
    }

    private func request(method: String, path: String, bodyObject: [String: Any]?) async throws -> [String: Any] {
        let body: Data
        if let bodyObject {
            body = try JSONSerialization.data(withJSONObject: bodyObject, options: [])
        } else {
            body = Data()
        }
        return try await rawRequest(method: method, path: path, body: body, useToken: true)
    }

    private func rawRequest(method: String, path: String, body: Data, useToken: Bool) async throws -> [String: Any] {
        let now = String(Int64(Date().timeIntervalSince1970 * 1000))
        let token = useToken ? accessToken : ""

        var signedHeaders = ""
        var headers: [String: String] = [:]
        if method == "POST" {
            headers["Content-type"] = "application/json"
            headers["Signature-Headers"] = "Content-type"
            signedHeaders = "Content-type:application/json\n"
        }

        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let stringToSign = method + "\n" + bodyHash + "\n" + signedHeaders + "\n" + path
        let signPayload = config.tuyaClientID + token + now + stringToSign
        let key = SymmetricKey(data: Data(config.tuyaClientSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signPayload.utf8), using: key)
            .map { String(format: "%02X", $0) }
            .joined()

        headers["client_id"] = config.tuyaClientID
        headers["sign"] = signature
        headers["t"] = now
        headers["sign_method"] = "HMAC-SHA256"
        headers["mode"] = "cors"
        if useToken {
            headers["access_token"] = accessToken
        }

        let host = try TuyaRegion.normalizedHost(config.tuyaAPIHost)
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw TuyaCloudAPIError(message: "Host de Tuya inválido.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if method == "POST" {
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TuyaCloudAPIError(message: "Tuya Cloud respondió con un error HTTP.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TuyaCloudAPIError(message: "Respuesta inválida de Tuya Cloud.")
        }
        if let success = object["success"] as? Bool, !success {
            throw TuyaCloudAPIError(message: "Tuya rechazó la solicitud. Revisá los permisos y credenciales de tu proyecto.")
        }
        return object
    }
}

final class CloudRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
