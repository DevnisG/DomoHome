import Foundation
import CryptoKit

enum ConfigurationError: LocalizedError {
    case missingFile
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return L10n.text("Sin configurar. Agregá un dispositivo en Ajustes.")
        case .invalid(let message):
            return L10n.text(message)
        }
    }
}

struct LightConfiguration: Identifiable, Sendable {
    let name: String
    let deviceID: String
    let ip: String
    let localKey: String
    let version: Double
    let displayName: String?
    let group: String?

    var id: String { deviceID }
}

struct LightsConfiguration: Sendable {
    let tuyaSwitchDPID: Int
    let lights: [LightConfiguration]
}

struct LockConfiguration: Sendable {
    let tuyaClientID: String
    let tuyaClientSecret: String
    let tuyaAPIHost: String
    let lockDeviceID: String
    let displayName: String?
    let group: String?
}

struct LightGroup: Identifiable {
    let id: String
    let title: String
    let lights: [LightConfiguration]

    var shortcutActionID: String {
        let members = lights.map(\.id).sorted().map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(members.utf8)).map { String(format: "%02x", $0) }.joined()
        return "light:members:\(digest)"
    }

    var subtitle: String {
        lights.count == 1 ? L10n.text("1 dispositivo") : L10n.format("%@ dispositivos", String(lights.count))
    }
}

enum DevicePowerState {
    case on
    case off
    case mixed
    case unknown
}

struct LightSettingsItem: Identifiable, Equatable {
    let id: String
    let defaultLabel: String
    let defaultGroup: String
}
