import Foundation
import CryptoKit

struct TuyaCloudAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { L10n.text(message) }
}

actor TuyaCloudClient {
    private let config: LockConfiguration
    private let session: URLSession
    private var accessToken = ""
    private var tokenExpiry = Date.distantPast

    init(config: LockConfiguration) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration, delegate: CloudRedirectPolicy(), delegateQueue: nil)
    }

    func unlock() async throws -> Bool {
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

        let response = try await request(
            method: "POST",
            path: "/v1.0/devices/\(config.lockDeviceID)/door-lock/password-free/open-door",
            bodyObject: ["ticket_id": ticket]
        )
        return (response["result"] as? Bool) ?? false
    }

    func status() async throws -> [String: Any] {
        try await ensureToken()
        let response = try await request(
            method: "GET",
            path: "/v1.0/iot-03/devices/\(config.lockDeviceID)/status",
            bodyObject: nil
        )

        var state: [String: Any] = [:]
        if let list = response["result"] as? [[String: Any]] {
            for item in list {
                if let code = item["code"] as? String, let value = item["value"] {
                    state[code] = value
                }
            }
        }
        return state
    }

    func waitAndUnlock(timeout: TimeInterval = 120) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            if let state = try? await status() {
                let countdown: Double
                if let value = state["unlock_request"] as? Double {
                    countdown = value
                } else if let value = state["unlock_request"] as? NSNumber {
                    countdown = value.doubleValue
                } else {
                    countdown = 0
                }

                if countdown > 0, let opened = try? await unlock() {
                    return opened
                }
            }
            try await Task.sleep(for: .milliseconds(800))
        }
        throw TuyaCloudAPIError(message: "Timeout esperando el countdown del timbre (120 s).")
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
