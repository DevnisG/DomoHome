import CryptoKit
import Darwin
import Foundation
import Security

final class TuyaMessageProcessAdapter: TuyaMessageStream, @unchecked Sendable {
    private let stream: AsyncStream<TuyaMessage>
    private let continuation: AsyncStream<TuyaMessage>.Continuation
    private let lock = NSLock()
    private var process: Process?
    private var worker: Task<Void, Never>?
    private var stopped = false
    private let environment: String

    init(configuration: LockConfiguration, settings: TuyaDoorbellSettings) {
        environment = settings.environment.rawValue
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
        worker = Task.detached { [weak self] in
            self?.supervise(configuration: configuration, settings: settings)
        }
    }

    deinit { stop() }

    func messages() -> AsyncStream<TuyaMessage> { stream }

    func stop() {
        lock.lock()
        stopped = true
        let active = process
        lock.unlock()
        worker?.cancel()
        if let active, active.isRunning {
            active.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if active.isRunning { kill(active.processIdentifier, SIGKILL) }
            }
        }
        continuation.finish()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func connection(_ state: String) {
        continuation.yield(TuyaMessage(type: "connection", state: state, environment: environment))
    }

    private func supervise(configuration: LockConfiguration, settings: TuyaDoorbellSettings) {
        let digest = SHA256.hash(data: Data((configuration.tuyaClientID + environment).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let lockPath = NSTemporaryDirectory() + "domohome-tuya-\(digest).lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            connection("ConsumerAlreadyRunning")
            return
        }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        var retry = 0
        while !isStopped {
            do {
                try run(configuration: configuration, settings: settings)
            } catch let error as TuyaMessageError {
                connection(error.rawValue)
                if error == .configurationMissing || error == .authFailure { return }
            } catch {
                connection(TuyaMessageError.connectionLost.rawValue)
            }
            guard !isStopped else { return }
            retry = min(retry + 1, 6)
            let delay = min(60, pow(2, Double(retry))) + Double.random(in: 0...1)
            let until = ProcessInfo.processInfo.systemUptime + delay
            while !isStopped && ProcessInfo.processInfo.systemUptime < until {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private func verifiedExecutable() throws -> URL {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TuyaMessageService")
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber,
              mode.intValue & 0o022 == 0 else { throw TuyaMessageError.configurationMissing }
        var code: SecStaticCode?
        var parent: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &parent) == errSecSuccess,
              let parent,
              SecStaticCodeCheckValidity(parent, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw TuyaMessageError.configurationMissing }
        var parentInfo: CFDictionary?
        var childInfo: CFDictionary?
        SecCodeCopySigningInformation(parent, [], &parentInfo)
        SecCodeCopySigningInformation(code, [], &childInfo)
        let parentTeam = (parentInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        let childTeam = (childInfo as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        guard parentTeam == childTeam else { throw TuyaMessageError.configurationMissing }
        return url
    }

    private func run(configuration: LockConfiguration, settings: TuyaDoorbellSettings) throws {
        let executable = try verifiedExecutable()
        guard configuration.tuyaAPIHost == TuyaRegion.westernAmerica.rawValue else {
            throw TuyaMessageError.configurationMissing
        }
        connection("connecting")
        let child = Process()
        child.executableURL = executable
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "DOTNET_EnableDiagnostics": "0"]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        process = child
        do { try child.run() } catch { lock.unlock(); throw TuyaMessageError.connectionLost }
        lock.unlock()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if child.isRunning {
                child.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
            child.waitUntilExit()
            lock.lock()
            process = nil
            lock.unlock()
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "accessId": configuration.tuyaClientID,
            "accessSecret": configuration.tuyaClientSecret,
            "deviceId": configuration.lockDeviceID,
            "environment": settings.environment.rawValue
        ])
        try input.fileHandleForWriting.write(contentsOf: data + Data([10]))
        try input.fileHandleForWriting.close()
        var buffer = Data()
        while !isStopped {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            guard buffer.count <= 262_144 else { throw TuyaMessageError.decodingFailure }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard line.count <= 16_384,
                      let message = try? JSONDecoder().decode(TuyaMessage.self, from: line),
                      message.schemaVersion == 1 else { throw TuyaMessageError.decodingFailure }
                if message.type == "connection", message.state == TuyaMessageError.authFailure.rawValue {
                    continuation.yield(message)
                    throw TuyaMessageError.authFailure
                }
                if case .dropped = continuation.yield(message) { throw TuyaMessageError.connectionLost }
            }
        }
        if !isStopped { throw TuyaMessageError.connectionLost }
    }
}
