import Foundation

struct EnvironmentImport {
    let lights: LightsConfiguration?
    let lock: LockConfiguration?
}

enum EnvironmentConfiguration {
    static var url: URL {
        if let customPath = ProcessInfo.processInfo.environment["DOMOHOME_ENV_FILE"], !customPath.isEmpty {
            return URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
        }
        #if DEBUG
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".env")
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DomoHome", isDirectory: true).appendingPathComponent(".env")
        #endif
    }

    static func loadImport(at source: URL) throws -> EnvironmentImport {
        let values: [String: String]
        do {
            let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  (attributes.fileSize ?? 0) <= 1_048_576 else {
                throw ConfigurationError.invalid("No se pudo leer el archivo .env privado.")
            }
            values = try parse(String(contentsOf: source, encoding: .utf8))
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.invalid("No se pudo leer el archivo .env privado.")
        }
        let hasLights = values.contains { ($0.key == "LIGHT_COUNT" || $0.key.hasPrefix("LIGHT_")) && !$0.value.isEmpty }
        let hasLock = ["TUYA_CLIENT_ID", "TUYA_CLIENT_SECRET", "LOCK_DEVICE_ID"].contains { !(values[$0] ?? "").isEmpty }
        return EnvironmentImport(lights: hasLights ? try loadLights(values) : nil,
                                 lock: hasLock ? try loadLock(values) : nil)
    }

    private static func loadLights(_ values: [String: String]) throws -> LightsConfiguration {
        guard let dpid = Int(try required("TUYA_SWITCH_DPID", in: values)), (1...255).contains(dpid) else {
            throw ConfigurationError.invalid("Usá un DPID entre 1 y 255 y hasta 64 luces.")
        }
        guard let count = Int(try required("LIGHT_COUNT", in: values)), (1...64).contains(count) else {
            throw ConfigurationError.invalid("La cantidad de luces debe estar entre 1 y 64.")
        }
        let lights = try (1...count).map { index in
            let prefix = "LIGHT_\(index)"
            guard let version = Double(try required("\(prefix)_VERSION", in: values)) else {
                throw ConfigurationError.invalid(L10n.format("La versión de la luz %@ no es válida.", String(index)))
            }
            return LightConfiguration(name: "light-\(index)", deviceID: try required("\(prefix)_DEVICE_ID", in: values),
                                      ip: try required("\(prefix)_IP", in: values),
                                      localKey: try required("\(prefix)_LOCAL_KEY", in: values), version: version,
                                      displayName: values["\(prefix)_NAME"], group: values["\(prefix)_GROUP"])
        }
        return LightsConfiguration(tuyaSwitchDPID: dpid, lights: lights)
    }

    private static func loadLock(_ values: [String: String]) throws -> LockConfiguration {
        LockConfiguration(tuyaClientID: try required("TUYA_CLIENT_ID", in: values),
                          tuyaClientSecret: try required("TUYA_CLIENT_SECRET", in: values),
                          tuyaAPIHost: try required("TUYA_API_HOST", in: values),
                          lockDeviceID: try required("LOCK_DEVICE_ID", in: values), displayName: values["LOCK_NAME"],
                          group: values["LOCK_GROUP"])
    }

    private static func required(_ key: String, in values: [String: String]) throws -> String {
        guard let value = values[key], !value.isEmpty else {
            throw ConfigurationError.invalid(L10n.format("Falta %@ en la configuración.", key))
        }
        return value
    }

    private static func parse(_ content: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for (index, line) in content.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let failure = ConfigurationError.invalid(L10n.format("Formato .env inválido en la línea %@. Revisá las comillas y las claves duplicadas.", String(index + 1)))
            guard let separator = trimmed.firstIndex(of: "=") else { throw failure }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  values[key] == nil else { throw failure }
            let raw = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            let value: String
            if raw.hasPrefix("\"") {
                guard let decoded = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { throw failure }
                value = decoded
            } else if raw.hasPrefix("'") {
                guard raw.count >= 2, raw.hasSuffix("'") else { throw failure }
                value = String(raw.dropFirst().dropLast())
            } else {
                value = raw
            }
            values[key] = value
        }
        return values
    }
}
