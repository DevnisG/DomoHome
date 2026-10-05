import Foundation
import Security

protocol CredentialStore {
    func read(_ reference: String) throws -> String
    func insert(_ secret: String, reference: String) throws
    func remove(_ reference: String) throws
}

struct KeychainCredentialStore: CredentialStore {
    private let service = "org.domohome.DomoHome.credentials"

    func read(_ reference: String) throws -> String {
        var query = try query(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8), !secret.isEmpty else {
            throw failure(status)
        }
        return secret
    }

    func insert(_ secret: String, reference: String) throws {
        var attributes = try query(reference)
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrLabel as String] = "DomoHome"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    func remove(_ reference: String) throws {
        let status = SecItemDelete(try query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func query(_ reference: String) throws -> [String: Any] {
        guard UUID(uuidString: reference) != nil else {
            throw ConfigurationError.invalid("La referencia de una credencial es inválida.")
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false
        ]
    }

    private func failure(_ status: OSStatus) -> ConfigurationError {
        if status == errSecItemNotFound {
            return .invalid("Falta una credencial en el llavero. Volvé a configurarla en Ajustes.")
        }
        return .invalid("No se pudo acceder al llavero de macOS. Desbloquealo y volvé a intentar.")
    }
}
