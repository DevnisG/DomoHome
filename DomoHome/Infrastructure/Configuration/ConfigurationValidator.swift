import Darwin
import Foundation

struct ConfigurationValidator {
    static func validate(_ document: ConfigurationDocument) throws {
        guard document.schemaVersion == 1 else {
            throw ConfigurationError.invalid("La versión de configuración no es compatible.")
        }
        guard (1...255).contains(document.switchDPID), document.lights.count <= 64 else {
            throw ConfigurationError.invalid("Usá un DPID entre 1 y 255 y hasta 64 luces.")
        }
        let ids = document.lights.map(\.deviceID)
        let references = document.lights.map(\.credentialReference) + [document.lock?.credentialReference].compactMap { $0 }
        guard Set(ids).count == ids.count, Set(references).count == references.count else {
            throw ConfigurationError.invalid("Hay dispositivos o credenciales duplicados.")
        }
        for light in document.lights {
            guard validIdentifier(light.deviceID), validIP(light.ip), light.version == 3.3 else {
                throw ConfigurationError.invalid("Revisá el ID, la dirección IP y la versión 3.3 de la luz.")
            }
            try validateName(light.displayName)
            try validateName(light.group)
        }
        if let lock = document.lock {
            guard validIdentifier(lock.clientID), validIdentifier(lock.deviceID) else {
                throw ConfigurationError.invalid("La configuración de la cerradura está incompleta o es inválida.")
            }
            _ = try TuyaRegion.normalizedHost(lock.apiHost)
            try validateName(lock.displayName)
            try validateName(lock.group)
        }
        guard references.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw ConfigurationError.invalid("La referencia de una credencial es inválida.")
        }
    }

    static func validateName(_ value: String) throws {
        guard value.count <= 80, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError.invalid("Los nombres y grupos admiten hasta 80 caracteres sin saltos de línea.")
        }
    }

    static func validateLocalKey(_ value: String) throws {
        guard value.utf8.count == 16 else {
            throw ConfigurationError.invalid("La local_key de Tuya debe tener exactamente 16 bytes.")
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
    }

    private static func validIP(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
}
