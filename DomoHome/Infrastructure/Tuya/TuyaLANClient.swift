import Foundation
import Network

enum TuyaLANError: LocalizedError {
    case invalidKey
    case connection(String)
    case timeout
    case connectionClosed
    case invalidPacket(String)
    case device(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .invalidKey: return L10n.text("La local_key de Tuya debe tener exactamente 16 bytes.")
        case .connection(let value): return L10n.format("No se pudo conectar al dispositivo: %@", value)
        case .timeout: return L10n.text("Tiempo de espera agotado para el dispositivo.")
        case .connectionClosed: return L10n.text("El dispositivo cerró la conexión.")
        case .invalidPacket(let value): return L10n.format("Respuesta Tuya inválida: %@", value)
        case .device(let value): return L10n.format("El dispositivo Tuya devolvió un error: %@", value)
        case .invalidJSON: return L10n.text("La respuesta de Tuya no contiene JSON válido.")
        }
    }
}

private final class ConnectionResult: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let continuation: CheckedContinuation<NWConnection, Error>
    private var completed = false

    init(connection: NWConnection, continuation: CheckedContinuation<NWConnection, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<NWConnection, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        connection.stateUpdateHandler = nil
        lock.unlock()

        if case .failure = result {
            connection.cancel()
        }
        continuation.resume(with: result)
    }
}

private final class ConnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var completed = false
    private var timedOut = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    var didTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func expire() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        timedOut = true
        completed = true
        lock.unlock()
        connection.cancel()
    }

    func finish() {
        lock.lock()
        completed = true
        lock.unlock()
        connection.cancel()
    }
}

struct TuyaLANClient: Sendable {
    private let config: LightConfiguration
    private let timeout: TimeInterval

    private static let port: NWEndpoint.Port = 6668
    private static let prefix: UInt32 = 0x000055AA
    private static let suffix: UInt32 = 0x0000AA55
    private static let commandControl: UInt32 = 0x07
    private static let commandQuery: UInt32 = 0x0A
    private static let versionHeaderLength = 15

    init(config: LightConfiguration, timeout: TimeInterval = 8) {
        self.config = config
        self.timeout = timeout
    }

    func status() async throws -> [String: Any] {
        let now = String(Int(Date().timeIntervalSince1970))
        let payload: [String: Any] = [
            "gwId": config.deviceID,
            "devId": config.deviceID,
            "uid": config.deviceID,
            "t": now
        ]
        return try await sendCommand(Self.commandQuery, payload: payload, hasVersionHeader: false)
    }

    func setStatus(_ on: Bool, dpid: Int) async throws {
        let now = String(Int(Date().timeIntervalSince1970))
        let payload: [String: Any] = [
            "devId": config.deviceID,
            "uid": config.deviceID,
            "t": now,
            "dps": [String(dpid): on]
        ]
        _ = try await sendCommand(Self.commandControl, payload: payload, hasVersionHeader: true)
    }

    func switchValue(from response: [String: Any], dpid: Int) -> Bool? {
        let dps: [String: Any]?
        if let direct = response["dps"] as? [String: Any] {
            dps = direct
        } else if let data = response["data"] as? [String: Any],
                  let nested = data["dps"] as? [String: Any] {
            dps = nested
        } else {
            dps = nil
        }
        guard let dps else { return nil }
        if let value = dps[String(dpid)] as? Bool { return value }
        if let number = dps[String(dpid)] as? NSNumber { return number.boolValue }
        return nil
    }

    private func sendCommand(_ command: UInt32, payload: [String: Any], hasVersionHeader: Bool) async throws -> [String: Any] {
        guard let key = config.localKey.data(using: .utf8), key.count == 16 else {
            throw TuyaLANError.invalidKey
        }

        let json = try JSONSerialization.data(withJSONObject: payload, options: [])
        var encrypted = try AES128ECB.encrypt(json, key: key)

        if hasVersionHeader {
            var header = Data("3.3".utf8)
            header.append(Data(repeating: 0, count: Self.versionHeaderLength - 3))
            header.append(encrypted)
            encrypted = header
        }

        let packet = pack(command: command, payload: encrypted)
        let connection = NWConnection(host: NWEndpoint.Host(config.ip), port: Self.port, using: .tcp)
        let lifetime = ConnectionLifetime(connection: connection)
        let deadline = DispatchWorkItem { lifetime.expire() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            lifetime.finish()
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                _ = try await connect(connection)
                try await send(packet, over: connection)
                let response = try await readResponse(from: connection, key: key)
                guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
                    throw TuyaLANError.invalidJSON
                }
                if let error = object["Err"] as? String { throw TuyaLANError.device(error) }
                return object
            } onCancel: {
                lifetime.finish()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if lifetime.didTimeout { throw TuyaLANError.timeout }
            throw error
        }
    }

    private func pack(command: UInt32, payload: Data) -> Data {
        let sequence = UInt32.random(in: 1...UInt32.max - 1)
        var packet = Data()
        packet.appendUInt32BE(Self.prefix)
        packet.appendUInt32BE(sequence)
        packet.appendUInt32BE(command)
        packet.appendUInt32BE(UInt32(payload.count + 8))
        packet.append(payload)
        packet.appendUInt32BE(CRC32.checksum(packet))
        packet.appendUInt32BE(Self.suffix)
        return packet
    }

    private func connect(_ connection: NWConnection) async throws -> NWConnection {
        let queue = DispatchQueue(label: "DomoHome.Tuya.\(config.name).\(UUID().uuidString)")

        return try await withCheckedThrowingContinuation { continuation in
            let completion = ConnectionResult(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(.success(connection))
                case .failed(let error):
                    completion.finish(.failure(TuyaLANError.connection(error.localizedDescription)))
                case .cancelled:
                    completion.finish(.failure(TuyaLANError.connectionClosed))
                case .waiting:
                    break
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: TuyaLANError.connection(error.localizedDescription))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    private func receiveExact(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: TuyaLANError.connection(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: TuyaLANError.connectionClosed)
                    } else {
                        continuation.resume(throwing: TuyaLANError.connectionClosed)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private func readResponse(from connection: NWConnection, key: Data) async throws -> Data {
        let header = try await receiveExact(16, from: connection)
        guard header.uint32BE(at: 0) == Self.prefix else {
            throw TuyaLANError.invalidPacket(L10n.text("prefijo incorrecto"))
        }

        let length = Int(header.uint32BE(at: 12))
        guard length >= 12, length <= 1_048_576 else {
            throw TuyaLANError.invalidPacket(L10n.format("longitud %@", String(length)))
        }

        let rest = try await receiveExact(length, from: connection)
        guard rest.count >= 12 else {
            throw TuyaLANError.invalidPacket(L10n.text("respuesta demasiado corta"))
        }

        let returnCode = rest.uint32BE(at: 0)
        let crcOffset = rest.count - 8
        let suffixOffset = rest.count - 4
        let expectedCRC = rest.uint32BE(at: crcOffset)
        let suffix = rest.uint32BE(at: suffixOffset)

        guard suffix == Self.suffix else {
            throw TuyaLANError.invalidPacket(L10n.text("sufijo incorrecto"))
        }

        var crcData = Data()
        crcData.append(header)
        crcData.append(rest.prefix(crcOffset))
        let actualCRC = CRC32.checksum(crcData)
        guard expectedCRC == actualCRC else {
            throw TuyaLANError.invalidPacket(L10n.text("CRC inválido"))
        }

        var body = Data(rest[4..<crcOffset])
        if returnCode != 0 {
            throw TuyaLANError.device("retcode=\(returnCode)")
        }

        if body.count >= 3, String(data: body.prefix(3), encoding: .utf8) == "3.3" {
            guard body.count >= Self.versionHeaderLength else {
                throw TuyaLANError.invalidPacket(L10n.text("cabecera 3.3 incompleta"))
            }
            body.removeFirst(Self.versionHeaderLength)
        }

        return try AES128ECB.decrypt(body, key: key)
    }
}
