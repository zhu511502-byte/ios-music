import Foundation
import Security

enum SyncCrypto {
    static let helloMessage = "Hello~::^-^::~v4~"
    static let authMessage = "lx-music auth::"
    static let connectMessage = "lx-music connect"

    struct RSAKeyPair {
        let privateKey: SecKey
        let publicKey: SecKey
        let publicKeySPKIBase64: String

        static func generate() throws -> RSAKeyPair {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits: 2048,
                kSecPrivateKeyAttrs: [
                    kSecAttrIsPermanent: false
                ]
            ]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                throw SyncError.crypto("无法生成 RSA 密钥")
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw SyncError.crypto("无法导出 RSA 公钥")
            }
            guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) else {
                throw SyncError.crypto("无法导出 RSA 公钥数据")
            }
            let pkcs1Data = pkcs1 as Data
            let algorithm = SyncCrypto.derSequence(RSAKeyPair.rsaAlgorithmIdentifier())
            var bitStringData = Data([0x00])
            bitStringData.append(contentsOf: pkcs1Data)
            let bitString = SyncCrypto.derElement(0x03, bitStringData)
            var spkiContent = Data()
            spkiContent.append(contentsOf: algorithm)
            spkiContent.append(contentsOf: bitString)
            let spki = SyncCrypto.derSequence(spkiContent)
            return RSAKeyPair(privateKey: privateKey, publicKey: publicKey,
                              publicKeySPKIBase64: spki.base64EncodedString())
        }

        private static func rsaAlgorithmIdentifier() -> Data {
            // OID 1.2.840.113549.1.1.1 + NULL
            Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        }
    }

    static func md5Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func authKey(from code: String) -> Data {
        // 洛雪端：md5(code) 取前 16 个十六进制字符，再作为 AES-128 key 的 16 个 ASCII 字节。
        let hex = md5Hex(code)
        return Data(String(hex.prefix(16)).utf8)
    }

    static func aes128ECBEncrypt(_ data: Data, key: Data) throws -> Data {
        try aes128ECB(data, key: key, decrypt: false)
    }

    static func aes128ECBDecrypt(_ data: Data, key: Data) throws -> Data {
        try aes128ECB(data, key: key, decrypt: true)
    }

    private static func aes128ECB(_ data: Data, key: Data, decrypt: Bool) throws -> Data {
        guard key.count == Int(kCCKeySizeAES128) else {
            throw SyncError.crypto("AES key 必须是 16 字节")
        }
        var output = Data(count: data.count + Int(kCCBlockSizeAES128))
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(decrypt ? kCCDecrypt : kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress, key.count, nil,
                        dataBuffer.baseAddress, data.count,
                        outputBuffer.baseAddress, outputBuffer.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw SyncError.crypto("AES 操作失败：\(status)")
        }
        output.removeSubrange(moved..<output.count)
        return output
    }

    static func rsaEncryptOAEP(_ data: Data, publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let result = SecKeyCreateEncryptedData(
            publicKey, .rsaEncryptionOAEPSHA1, data as CFData, &error
        ) else {
            throw SyncError.crypto("RSA OAEP 加密失败")
        }
        return result as Data
    }

    static func rsaDecryptOAEP(_ data: Data, privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let result = SecKeyCreateDecryptedData(
            privateKey, .rsaEncryptionOAEPSHA1, data as CFData, &error
        ) else {
            throw SyncError.crypto("RSA OAEP 解密失败")
        }
        return result as Data
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let address = buffer.baseAddress {
                _ = SecRandomCopyBytes(kSecRandomDefault, count, address)
            }
        }
        return data
    }

    fileprivate static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([UInt8(0x80) | UInt8(bytes.count)] + bytes)
    }

    fileprivate static func derElement(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: derLength(content.count))
        result.append(contentsOf: content)
        return result
    }

    fileprivate static func derSequence(_ content: Data) -> Data {
        derElement(0x30, content)
    }
}
