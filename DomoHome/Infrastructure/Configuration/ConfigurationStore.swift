import Darwin
import Foundation

final class DeviceConfigurationRepository {
    let url: URL
    private let credentials: CredentialStore
    private let access = NSRecursiveLock()

    init(url: URL, credentials: CredentialStore) {
        self.url = url
        self.credentials = credentials
    }

    func document() throws -> ConfigurationDocument {
        try synchronized { try readDocument() }
    }

    func restoreDocument(_ document: ConfigurationDocument) throws {
        try synchronized {
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try writeDocument(document)
        }
    }

    func loadLights() throws -> LightsConfiguration {
        try synchronized {
            let document = try readDocument()
            guard !document.lights.isEmpty else { throw ConfigurationError.missingFile }
            let lights = try document.lights.enumerated().map { index, record in
                let key = try credentials.read(record.credentialReference)
                try ConfigurationValidator.validateLocalKey(key)
                return LightConfiguration(name: "light-\(index + 1)", deviceID: record.deviceID,
                                          ip: record.ip, localKey: key, version: record.version,
                                          displayName: record.displayName, group: record.group)
            }
            return LightsConfiguration(tuyaSwitchDPID: document.switchDPID, lights: lights)
        }
    }

    func loadLock() throws -> LockConfiguration {
        try synchronized {
            guard let record = try readDocument().lock else { throw ConfigurationError.missingFile }
            let secret = try credentials.read(record.credentialReference)
            guard !secret.isEmpty else { throw ConfigurationError.missingFile }
            return LockConfiguration(tuyaClientID: record.clientID, tuyaClientSecret: secret,
                                     tuyaAPIHost: try TuyaRegion.normalizedHost(record.apiHost),
                                     lockDeviceID: record.deviceID, displayName: record.displayName, group: record.group)
        }
    }

    func updateLabels(_ updates: [DeviceLabelUpdate], lockName: String, lockGroup: String? = nil) throws {
        try synchronized {
            var document = try readDocument()
            guard Set(updates.map(\.id)) == Set(document.lights.map(\.id)),
                  updates.count == document.lights.count else {
                throw ConfigurationError.invalid("El dispositivo cambió. Recargá la configuración.")
            }
            for update in updates {
                guard let index = document.lights.firstIndex(where: { $0.id == update.id }) else { continue }
                document.lights[index].displayName = update.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                document.lights[index].group = update.group.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            document.lock?.displayName = lockName.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lockGroup { document.lock?.group = lockGroup.trimmingCharacters(in: .whitespacesAndNewlines) }
            try writeDocument(document)
        }
    }

    func saveLight(_ setup: LightSetup) throws {
        try synchronized {
            var document = try readDocument()
            let index = setup.originalID.flatMap { id in document.lights.firstIndex(where: { $0.id == id }) }
            if setup.originalID != nil && index == nil {
                throw ConfigurationError.invalid("El dispositivo cambió. Recargá la configuración.")
            }
            let previous = index.map { document.lights[$0] }
            let key = setup.localKey.isEmpty ? try credentials.read(requiredReference(previous?.credentialReference)) : setup.localKey
            try ConfigurationValidator.validateLocalKey(key)
            let reference = setup.localKey.isEmpty ? previous!.credentialReference : UUID().uuidString
            let record = StoredLight(deviceID: setup.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                                     ip: setup.ip.trimmingCharacters(in: .whitespacesAndNewlines), version: 3.3,
                                     displayName: setup.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                     group: setup.group.trimmingCharacters(in: .whitespacesAndNewlines),
                                     credentialReference: reference)
            document.switchDPID = setup.switchDPID
            if let index { document.lights[index] = record } else { document.lights.append(record) }
            try commit(document, newSecrets: setup.localKey.isEmpty ? [:] : [reference: key],
                       retiredReferences: [previous?.credentialReference].compactMap { $0 }.filter { $0 != reference })
        }
    }

    func saveLock(_ setup: LockSetup) throws {
        try synchronized {
            var document = try readDocument()
            let previous = document.lock
            let secret = setup.clientSecret.isEmpty ? try credentials.read(requiredReference(previous?.credentialReference)) : setup.clientSecret
            guard !secret.isEmpty, secret.utf8.count <= 4096 else {
                throw ConfigurationError.invalid("Completá el secreto de Tuya.")
            }
            let reference = setup.clientSecret.isEmpty ? previous!.credentialReference : UUID().uuidString
            document.lock = StoredLock(clientID: setup.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                       apiHost: try TuyaRegion.normalizedHost(setup.apiHost),
                                       deviceID: setup.deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
                                       displayName: setup.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                       group: setup.group.trimmingCharacters(in: .whitespacesAndNewlines),
                                       credentialReference: reference)
            try commit(document, newSecrets: setup.clientSecret.isEmpty ? [:] : [reference: secret],
                       retiredReferences: [previous?.credentialReference].compactMap { $0 }.filter { $0 != reference })
        }
    }

    func removeLight(id: String) throws {
        try synchronized {
            var document = try readDocument()
            guard let record = document.lights.first(where: { $0.id == id }) else { return }
            document.lights.removeAll { $0.id == id }
            try writeDocument(document)
            try? credentials.remove(record.credentialReference)
        }
    }

    func removeLock() throws {
        try synchronized {
            var document = try readDocument()
            guard let record = document.lock else { return }
            document.lock = nil
            try writeDocument(document)
            try? credentials.remove(record.credentialReference)
        }
    }

    func importEnvironment(at source: URL) throws {
        try synchronized {
            guard try readDocument().credentialReferences.isEmpty else {
                throw ConfigurationError.invalid("Ya hay dispositivos configurados. Editalos desde Ajustes.")
            }
            let snapshot = try EnvironmentConfiguration.loadImport(at: source)
            var document = ConfigurationDocument()
            var secrets: [String: String] = [:]
            if let lights = snapshot.lights {
                document.switchDPID = lights.tuyaSwitchDPID
                for light in lights.lights {
                    try ConfigurationValidator.validateLocalKey(light.localKey)
                    let reference = UUID().uuidString
                    document.lights.append(StoredLight(deviceID: light.deviceID, ip: light.ip, version: light.version,
                                                       displayName: light.displayName ?? "", group: light.group ?? "",
                                                       credentialReference: reference))
                    secrets[reference] = light.localKey
                }
            }
            if let lock = snapshot.lock {
                let reference = UUID().uuidString
                document.lock = StoredLock(clientID: lock.tuyaClientID,
                                           apiHost: try TuyaRegion.normalizedHost(lock.tuyaAPIHost),
                                           deviceID: lock.lockDeviceID, displayName: lock.displayName ?? "",
                                           group: lock.group ?? "",
                                           credentialReference: reference)
                secrets[reference] = lock.tuyaClientSecret
            }
            guard !secrets.isEmpty else { throw ConfigurationError.missingFile }
            try commit(document, newSecrets: secrets, retiredReferences: [])
        }
    }

    private func commit(_ document: ConfigurationDocument, newSecrets: [String: String], retiredReferences: [String]) throws {
        try ConfigurationValidator.validate(document)
        var inserted: [String] = []
        do {
            for (reference, secret) in newSecrets {
                try credentials.insert(secret, reference: reference)
                inserted.append(reference)
                guard try credentials.read(reference) == secret else {
                    throw ConfigurationError.invalid("No se pudo verificar la credencial guardada.")
                }
            }
            try writeDocument(document)
        } catch {
            for reference in inserted { try? credentials.remove(reference) }
            throw error
        }
        for reference in retiredReferences { try? credentials.remove(reference) }
    }

    private func requiredReference(_ reference: String?) throws -> String {
        guard let reference else { throw ConfigurationError.invalid("Completá la credencial del dispositivo.") }
        return reference
    }

    private func readDocument() throws -> ConfigurationDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConfigurationDocument() }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= 1_048_576 else { throw ConfigurationError.invalid("Archivo inválido.") }
            let document = try JSONDecoder().decode(ConfigurationDocument.self, from: Data(contentsOf: url))
            try ConfigurationValidator.validate(document)
            return document
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.invalid("No se pudo leer la configuración local. Revisá Ajustes.")
        }
    }

    private func writeDocument(_ document: ConfigurationDocument) throws {
        try ConfigurationValidator.validate(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".configuration.\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ConfigurationError.invalid("Carpeta inválida.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw ConfigurationError.invalid("Archivo inválido.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temporary.path, url.path) == 0 else { throw ConfigurationError.invalid("Archivo inválido.") }
        } catch {
            throw ConfigurationError.invalid("No se pudo guardar la configuración local. Revisá los permisos de su carpeta.")
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        access.lock()
        defer { access.unlock() }
        return try operation()
    }
}

enum ConfigurationStore {
    static let repository = DeviceConfigurationRepository(url: url, credentials: KeychainCredentialStore())

    static var url: URL {
        #if DEBUG
        return EnvironmentConfiguration.url.deletingLastPathComponent()
            .appendingPathComponent(".domohome", isDirectory: true).appendingPathComponent("configuration.json")
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DomoHome", isDirectory: true)
            .appendingPathComponent("settings", isDirectory: true)
            .appendingPathComponent("configuration.json")
        #endif
    }

    private static var previousInstalledURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DomoHome", isDirectory: true)
            .appendingPathComponent("configuration.json")
    }

    static func prepare() throws {
        #if DEBUG
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: EnvironmentConfiguration.url.path) {
            try repository.importEnvironment(at: EnvironmentConfiguration.url)
        }
        #else
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.fileExists(atPath: previousInstalledURL.path) else { return }
        let previousRepository = DeviceConfigurationRepository(url: previousInstalledURL, credentials: KeychainCredentialStore())
        try repository.restoreDocument(previousRepository.document())
        #endif
    }

    static func loadLights() throws -> LightsConfiguration { try repository.loadLights() }
    static func loadLock() throws -> LockConfiguration { try repository.loadLock() }
}
