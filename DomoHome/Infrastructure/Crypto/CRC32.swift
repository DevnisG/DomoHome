import Foundation

enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }
}

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    func uint32BE(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        let i0 = index(startIndex, offsetBy: offset)
        let i1 = index(i0, offsetBy: 1)
        let i2 = index(i0, offsetBy: 2)
        let i3 = index(i0, offsetBy: 3)
        return (UInt32(self[i0]) << 24)
            | (UInt32(self[i1]) << 16)
            | (UInt32(self[i2]) << 8)
            | UInt32(self[i3])
    }
}
