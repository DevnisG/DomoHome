import Foundation

struct ConfigurationDocument: Codable, Equatable {
    var schemaVersion = 1
    var switchDPID = 1
    var lights: [StoredLight] = []
    var lock: StoredLock?

    var credentialReferences: Set<String> {
        Set(lights.map(\.credentialReference) + [lock?.credentialReference].compactMap { $0 })
    }
}

struct StoredLight: Codable, Equatable, Identifiable {
    var deviceID: String
    var ip: String
    var version: Double
    var displayName: String
    var group: String
    var credentialReference: String

    var id: String { deviceID }
}

struct StoredLock: Codable, Equatable {
    var clientID: String
    var apiHost: String
    var deviceID: String
    var displayName: String
    var group: String
    var credentialReference: String

    init(clientID: String, apiHost: String, deviceID: String, displayName: String, group: String = "", credentialReference: String) {
        self.clientID = clientID
        self.apiHost = apiHost
        self.deviceID = deviceID
        self.displayName = displayName
        self.group = group
        self.credentialReference = credentialReference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try container.decode(String.self, forKey: .clientID)
        apiHost = try container.decode(String.self, forKey: .apiHost)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        displayName = try container.decode(String.self, forKey: .displayName)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        credentialReference = try container.decode(String.self, forKey: .credentialReference)
    }
}

struct DeviceLabelUpdate {
    let id: String
    let displayName: String
    let group: String
}

struct LightSetup {
    var originalID: String?
    var deviceID = ""
    var ip = ""
    var displayName = ""
    var group = ""
    var localKey = ""
    var switchDPID = 1
}

struct LockSetup {
    var clientID = ""
    var apiHost = TuyaRegion.westernAmerica.rawValue
    var deviceID = ""
    var displayName = ""
    var group = ""
    var clientSecret = ""
}

enum TuyaRegion: String, CaseIterable, Identifiable {
    case westernAmerica = "openapi.tuyaus.com"
    case easternAmerica = "openapi-ueaz.tuyaus.com"
    case centralEurope = "openapi.tuyaeu.com"
    case westernEurope = "openapi-weaz.tuyaeu.com"
    case china = "openapi.tuyacn.com"
    case india = "openapi.tuyain.com"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .westernAmerica: L10n.text("América occidental")
        case .easternAmerica: L10n.text("América oriental")
        case .centralEurope: L10n.text("Europa central")
        case .westernEurope: L10n.text("Europa occidental")
        case .china: L10n.text("China")
        case .india: L10n.text("India")
        }
    }

    static func normalizedHost(_ value: String) throws -> String {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = input.hasPrefix("https://") ? String(input.dropFirst(8)) : input
        guard TuyaRegion(rawValue: host) != nil else {
            throw ConfigurationError.invalid("Seleccioná una región oficial de Tuya.")
        }
        return host
    }
}
