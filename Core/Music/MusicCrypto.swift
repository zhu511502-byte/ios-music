import Foundation

/// Small crypto helpers used by the native platform clients (QQ `zzc` sign
/// and NetEase eapi). The sync client keeps its own helpers because it also
/// needs RSA key generation.
enum MusicCrypto {
    static func md5Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func aes128ECBPKCS7(_ data: Data, key: Data) throws -> Data {
        guard key.count == Int(kCCKeySizeAES128) else {
            throw MusicAPIError.invalidResponse("AES key 必须是 16 字节")
        }
        var output = Data(count: data.count + Int(kCCBlockSizeAES128))
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
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
            throw MusicAPIError.invalidResponse("AES 加密失败：\(status)")
        }
        output.removeSubrange(moved..<output.count)
        return output
    }

    /// QQ Music's `zzc` request signature.
    static func zzcSign(_ text: String) -> String {
        let hash = sha1Hex(Data(text.utf8))
        let part1Indexes = [23, 14, 6, 36, 16, 40, 7, 19]
        let part2Indexes = [16, 1, 32, 12, 19, 27, 8, 5]
        let scramble: [UInt8] = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179]
        let chars = Array(hash)
        func pick(_ indexes: [Int]) -> String {
            indexes.compactMap { index in
                index < chars.count ? String(chars[index]) : nil
            }.joined()
        }
        let part1 = pick(part1Indexes)
        let part2 = pick(part2Indexes)
        var bytes: [UInt8] = []
        for (index, value) in scramble.enumerated() {
            guard index * 2 + 2 <= hash.count else {
                bytes.append(value)
                continue
            }
            let start = hash.index(hash.startIndex, offsetBy: index * 2)
            let end = hash.index(start, offsetBy: 2)
            let byte = UInt8(String(hash[start..<end]), radix: 16) ?? 0
            bytes.append(value ^ byte)
        }
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "=", with: "")
        return ("zzc" + part1 + base64 + part2).lowercased()
    }

    static func randomHexString(count: Int) -> String {
        let characters = Array("0123456789ABCDEF")
        return String((0..<count).map { _ in characters.randomElement() ?? "0" })
    }
}
