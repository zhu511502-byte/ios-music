import Foundation

/// Decryptors for the enhanced lyric formats used by the platforms:
/// Kugou KRC (XOR + zlib), QQ QRC (3DES-ECB + zlib) and Kuwo's
/// base64/XOR container. Ported from the open-source kunyin Android player.
enum LyricCrypto {
    // MARK: - KRC

    private static let krcKey: [UInt8] = [
        64, 71, 97, 119, 94, 50, 116, 71,
        81, 54, 49, 45, 206, 210, 110, 105
    ]

    static func decryptKRC(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let payload = [UInt8](data.dropFirst(4))
        var decoded = [UInt8](repeating: 0, count: payload.count)
        for index in payload.indices {
            decoded[index] = payload[index] ^ krcKey[index % krcKey.count]
        }
        guard let inflated = try? Gzip.decompress(Data(decoded)) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    // MARK: - QRC

    private static let qrcKey: [UInt8] = [
        33, 64, 35, 41, 40, 42, 36, 37, 49, 50, 51, 90,
        88, 67, 33, 64, 33, 64, 35, 41, 40, 78, 72, 76
    ]

    static func decryptQRC(_ hex: String) -> String? {
        guard let encrypted = hexData(hex), encrypted.count % 8 == 0 else { return nil }
        guard let decrypted = tripleDESDecryptECB(encrypted, key: Data(qrcKey)) else { return nil }
        guard let inflated = try? Gzip.decompress(decrypted) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    // MARK: - Kuwo

    static func decryptKuwo(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var start = 0
        if bytes.count >= 4 {
            for index in 0...(bytes.count - 4) where bytes[index] == 0x0D
                && bytes[index + 1] == 0x0A
                && bytes[index + 2] == 0x0D
                && bytes[index + 3] == 0x0A {
                start = index + 4
                break
            }
        }
        guard let inflated = try? Gzip.decompress(data.subdata(in: start..<data.count)) else { return nil }
        guard let base64 = String(data: inflated, encoding: .utf8),
              let encoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return inflated
        }
        let key = Array("yeelion".utf8)
        var result = [UInt8](encoded)
        for index in result.indices {
            result[index] ^= key[index % key.count]
        }
        return Data(result)
    }

    // MARK: - Helpers

    private static func hexData(_ hex: String) -> Data? {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }
        var data = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = characters[index].hexDigitValue,
                  let low = characters[index + 1].hexDigitValue else { return nil }
            data.append(UInt8(high << 4 | low))
            index += 2
        }
        return data
    }

    private static func tripleDESDecryptECB(_ data: Data, key: Data) -> Data? {
        guard key.count == Int(kCCKeySize3DES) else { return nil }
        var output = Data(count: data.count + Int(kCCBlockSize3DES))
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithm3DES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress, key.count, nil,
                        dataBuffer.baseAddress, data.count,
                        outputBuffer.baseAddress, outputBuffer.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

/// Parses Kugou KRC text (`[start,duration]<offset,duration,0>char...`)
/// directly into word-timed lyric lines.
enum KRCParser {
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\[(\d+),(\d+)\](.*)$"#
    )
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"<(\d+),(\d+),\d+>([^<]*)"#
    )

    static func parse(_ raw: String) -> Lyrics? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [LyricLine] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            guard let match = linePattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) else {
                continue
            }
            let startMs = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let durationMs = Double(ns.substring(with: match.range(at: 2))) ?? 0
            guard durationMs > 0 else { continue } // metadata header rows

            let body = ns.substring(with: match.range(at: 3))
            let bodyNS = body as NSString
            let words = wordPattern.matches(in: body, options: [], range: NSRange(location: 0, length: bodyNS.length))
            guard !words.isEmpty else { continue }

            var text = ""
            var offsets: [Double] = []
            for word in words {
                let offsetMs = Double(bodyNS.substring(with: word.range(at: 1))) ?? 0
                let wordDurationMs = Double(bodyNS.substring(with: word.range(at: 2))) ?? 0
                let wordText = bodyNS.substring(with: word.range(at: 3))
                let characters = Array(wordText)
                let start = (startMs + offsetMs) / 1000
                let duration = max(wordDurationMs / 1000, 0.001)
                for index in characters.indices {
                    offsets.append(start + Double(index) / Double(max(characters.count, 1)) * duration)
                }
                text += wordText
            }

            let clean = MusicParse.htmlDecode(text.trimmingCharacters(in: .whitespaces))
            guard !clean.isEmpty else { continue }
            // Align offsets after trimming.
            let characters = Array(clean)
            let usedOffsets = offsets.count == characters.count
                ? offsets
                : redistribute(characters, start: startMs / 1000, duration: durationMs / 1000)
            lines.append(LyricLine(
                id: lines.count,
                time: startMs / 1000,
                text: clean,
                wordTimes: usedOffsets,
                endTime: (startMs + durationMs) / 1000
            ))
        }

        guard lines.count >= 2 else { return nil }
        return Lyrics(lines: lines, isSynced: true, isWordTimed: true)
    }

    private static func redistribute(_ characters: [Character], start: Double, duration: Double) -> [Double] {
        guard !characters.isEmpty else { return [] }
        let weights = characters.map { character -> Double in
            let scalar = character.unicodeScalars.first
            if let scalar, (scalar.value >= 0x2E80 && scalar.value <= 0x9FFF)
                || (scalar.value >= 0xFF00 && scalar.value <= 0xFFEF) {
                return 1.6
            }
            return character == " " ? 0.35 : 1.0
        }
        let total = max(weights.reduce(0, +), 0.001)
        var offsets: [Double] = []
        var accumulated = 0.0
        for weight in weights {
            offsets.append(start + accumulated / total * max(duration, 0.3))
            accumulated += weight
        }
        return offsets
    }
}
