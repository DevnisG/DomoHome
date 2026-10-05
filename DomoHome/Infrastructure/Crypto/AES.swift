import Foundation
import CommonCrypto

enum AESError: LocalizedError {
    case invalidKey
    case cryptFailed(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return L10n.text("La clave AES debe tener 16 bytes.")
        case .cryptFailed(let status):
            return L10n.format("Falló AES/ECB (CommonCrypto: %@).", String(status))
        }
    }
}

enum AES128ECB {
    static func encrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(data, key: key, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(data, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ data: Data, key: Data, operation: CCOperation) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw AESError.invalidKey }

        var buffer = Data(count: data.count + kCCBlockSizeAES128)
        let bufferCapacity = buffer.count
        var outputLength = 0
        let options = CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)

        let status: CCCryptorStatus = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                buffer.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        dataBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress,
                        bufferCapacity,
                        &outputLength
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw AESError.cryptFailed(status) }
        buffer.removeSubrange(outputLength..<buffer.count)
        return buffer
    }
}
