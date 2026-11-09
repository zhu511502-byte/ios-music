import Foundation

struct LyricSyllable: Hashable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let time: Double?
    let text: String
    /// Per-character start offsets relative to `time`, for karaoke highlighting.
    /// Empty when the source has no enhanced (krc/yrc/qrc) timing data.
    var wordTimes: [Double] = []
    /// When the whole line finishes singing (karaoke), if known.
    var endTime: Double?
    /// Original timed tokens from KRC/YRC/QRC. A token can be a single CJK
    /// character or a whole Latin word, and carries its real start/end.
    var syllables: [LyricSyllable] = []

    var hasWordTiming: Bool { !wordTimes.isEmpty && wordTimes.count == text.count }
    var hasSyllableTiming: Bool { !syllables.isEmpty }

    init(
        id: Int,
        time: Double?,
        text: String,
        wordTimes: [Double] = [],
        endTime: Double? = nil,
        syllables: [LyricSyllable] = []
    ) {
        self.id = id
        self.time = time
        self.text = text
        self.wordTimes = wordTimes
        self.endTime = endTime
        self.syllables = syllables
    }
}

struct Lyrics: Hashable, Sendable {
    var lines: [LyricLine]
    var isSynced: Bool
    /// True when per-character timings came from an enhanced format (yrc/krc).
    var isWordTimed: Bool = false

    var isEmpty: Bool { lines.isEmpty }
}

enum LyricsError: LocalizedError {
    case notFound
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notFound: return "这首歌暂时没有歌词"
        case .badURL: return "歌词地址无效"
        case .http(let code): return "歌词接口返回 HTTP \(code)"
        }
    }
}

/// Fetches LRC lyrics from the same public platform endpoints used by LX.
/// The service is deliberately best-effort: a missing lyric is not a playback error.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: Lyrics] = [:]

    func lyrics(for track: MusicInfo) async throws -> Lyrics {
        let key = track.id
        if let cached = cache[key] { return cached }

        var parsed: Lyrics?
        do {
            if let embedded = embeddedLyrics(track) {
                parsed = LyricsParser.parse(embedded)
            } else if let local = localSidecarLyrics(track) {
                parsed = LyricsParser.parse(local)
            } else if let url = lyricURL(track) {
                parsed = LyricsParser.parse((try? await fetchText(url)) ?? "")
                if parsed?.isEmpty != false {
                    parsed = LyricsParser.parse(try await platformLyrics(track))
                }
            } else {
                var wordLyrics: Lyrics?
                if track.source == "wy" {
                    wordLyrics = try? await neteaseYRCLyrics(track)
                } else if track.source == "kg" {
                    wordLyrics = await kugouKRCLyrics(track)
                }
                if let wordLyrics {
                    parsed = wordLyrics
                } else {
                    parsed = LyricsParser.parse(try await platformLyrics(track))
                }
            }
        } catch {
            // Fall through to the cross-platform search below.
            parsed = nil
        }

        // Platforms that only returned plain LRC still have no real
        // per-character timing. Kugou's public KRC search is a good fallback:
        // match title + singer, download the encrypted KRC and use its real
        // word offsets. This is what makes QQ/Kuwo lyrics high precision.
        if parsed?.isWordTimed != true, track.source != "local",
           let krc = await kugouKRCSearchLyrics(for: track) {
            parsed = krc
        }

        if parsed?.isEmpty != false {
            parsed = await fallbackLyrics(for: track)
        }

        guard let result = parsed, !result.isEmpty else { throw LyricsError.notFound }
        cache[key] = result
        return result
    }

    /// When the track's own platform has no usable lyric, search the other
    /// platforms by title/artist and use the first confident match.
    private func fallbackLyrics(for track: MusicInfo) async -> Lyrics? {
        let title = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let query = [title, track.singer]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")

        for source in ["wy", "tx", "kw", "kg"] where source != track.source {
            guard let page = try? await NativeMusicAPI.shared.search(source: source, query: query, page: 1, limit: 8),
                  !page.items.isEmpty else { continue }

            let normalizedTitle = normalize(title)
            let normalizedSinger = normalize(track.singer)
            let candidates = page.items.filter { item in
                let itemTitle = normalize(item.name)
                let itemSinger = normalize(item.singer)
                let titleMatches = itemTitle == normalizedTitle
                    || itemTitle.contains(normalizedTitle)
                    || normalizedTitle.contains(itemTitle)
                let singerMatches = normalizedSinger.isEmpty
                    || itemSinger.contains(normalizedSinger)
                    || normalizedSinger.contains(itemSinger)
                return titleMatches && singerMatches
            }

            for candidate in (candidates.isEmpty ? Array(page.items.prefix(1)) : Array(candidates.prefix(2))) {
                if let lyrics = await lyricsFromCandidate(candidate) {
                    return lyrics
                }
            }
        }
        return nil
    }

    private func lyricsFromCandidate(_ track: MusicInfo) async -> Lyrics? {
        if track.source == "wy", let yrc = try? await neteaseYRCLyrics(track), !yrc.isEmpty {
            return yrc
        }
        guard let text = try? await platformLyrics(track), !text.isEmpty else { return nil }
        let parsed = LyricsParser.parse(text)
        return parsed.isEmpty ? nil : parsed
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sources

    private func embeddedLyrics(_ track: MusicInfo) -> String? {
        for key in ["lyric", "lrc", "lyrics", "lyricText"] {
            if let value = track.meta[key]?.stringValue, !value.isEmpty { return value }
            if let object = track.meta[key]?.objectValue,
               let value = object["lyric"]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func localSidecarLyrics(_ track: MusicInfo) -> String? {
        guard track.source == "local", let path = track.localFilePath else { return nil }
        let base = URL(fileURLWithPath: path).deletingPathExtension()
        for ext in ["lrc", "LRC", "txt"] {
            let candidate = base.appendingPathExtension(ext)
            if let text = try? String(contentsOf: candidate, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func lyricURL(_ track: MusicInfo) -> URL? {
        guard let raw = track.meta["lrcUrl"]?.stringValue, !raw.isEmpty else { return nil }
        return normalizeURL(raw)
    }

    private func normalizeURL(_ raw: String) -> URL? {
        var text = MusicParse.htmlDecode(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        if text.hasPrefix("/") { text = "https://d.musicapp.migu.cn" + text }
        return URL(string: text)
    }

    private func platformLyrics(_ track: MusicInfo) async throws -> String {
        switch track.source {
        case "wy":
            let id = track.songID ?? ""
            guard !id.isEmpty else { throw LyricsError.notFound }
            let url = try makeURL("https://music.163.com/api/song/lyric", [
                ("id", id), ("lv", "1"), ("kv", "1"), ("tv", "-1")
            ])
            let body = try await fetchJSON(url, headers: ["Referer": "https://music.163.com/"])
            return MusicParse.string(MusicParse.dictionary(body["lrc"])["lyric"])

        case "tx":
            let id = track.songID ?? ""
            guard !id.isEmpty else { throw LyricsError.notFound }
            let url = try makeURL("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", [
                ("songmid", id), ("format", "json"), ("nobase64", "1")
            ])
            let body = try await fetchJSON(url, headers: ["Referer": "https://y.qq.com/"])
            var lyric = MusicParse.string(body["lyric"])
            if lyric.isEmpty { lyric = MusicParse.string(body["lyric_t"]) }
            if let data = Data(base64Encoded: lyric),
               let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
                lyric = decoded
            }
            return MusicParse.htmlDecode(lyric)

        case "kw":
            let id = track.songID ?? ""
            guard !id.isEmpty else { throw LyricsError.notFound }
            let url = try makeURL("https://m.kuwo.cn/newh5/singles/songinfoandlrc", [("musicId", id)])
            let body = try await fetchJSON(url)
            if let raw = body["lyric"] as? String, raw.contains("[") { return raw }
            let lines = MusicParse.objects(MusicParse.dictionary(body["data"])["lrclist"])
            return lines.compactMap { line in
                let text = MusicParse.htmlDecode(MusicParse.string(line["lineLyric"]))
                guard !text.isEmpty else { return nil }
                let seconds = MusicParse.double(line["time"])
                let minutes = Int(seconds) / 60
                let remainder = seconds - Double(minutes * 60)
                return String(format: "[%02d:%05.2f]%@", minutes, remainder, text)
            }.joined(separator: "\n")

        case "kg":
            let hash = track.meta["hash"]?.stringValue ?? ""
            guard !hash.isEmpty else { throw LyricsError.notFound }
            let searchURL = try makeURL("https://krcs.kugou.com/search", [
                ("ver", "1"), ("man", "yes"), ("client", "mobi"),
                ("keyword", ""), ("duration", ""), ("hash", hash)
            ])
            let search = try await fetchJSON(searchURL)
            guard let candidate = MusicParse.objects(search["candidates"]).first else {
                throw LyricsError.notFound
            }
            let id = MusicParse.string(candidate["id"])
            let accessKey = MusicParse.string(candidate["accesskey"])
            guard !id.isEmpty, !accessKey.isEmpty else { throw LyricsError.notFound }
            let downloadURL = try makeURL("https://lyrics.kugou.com/download", [
                ("ver", "1"), ("client", "pc"), ("id", id),
                ("accesskey", accessKey), ("fmt", "lrc"), ("charset", "utf8")
            ])
            let download = try await fetchJSON(downloadURL)
            let content = MusicParse.string(download["content"])
            if let data = Data(base64Encoded: content),
               let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty {
                return decoded
            }
            return content

        case "mg":
            throw LyricsError.notFound

        default:
            throw LyricsError.notFound
        }
    }

    // MARK: - NetEase enhanced lyrics (yrc)

    /// Fetches NetEase word-timed yrc lyrics. Returns nil when the song has
    /// no yrc data, so the caller falls back to plain LRC.
    private func neteaseYRCLyrics(_ track: MusicInfo) async throws -> Lyrics? {
        guard track.source == "wy", let id = track.songID, !id.isEmpty else { return nil }
        let url = try makeURL("https://interface3.music.163.com/api/song/lyric", [
            ("os", "pc"), ("id", id), ("lv", "1"), ("kv", "1"), ("tv", "-1"), ("yv", "1")
        ])
        var headers = ["Referer": "https://music.163.com/"]
        if let cookie = NativeMusicAPI.shared.neteaseCookie() {
            headers["Cookie"] = cookie
        }
        let body = try await fetchJSON(url, headers: headers)
        let yrcRoot = MusicParse.dictionary(body)["yrc"]
        var yrcText: String = ""
        if let root = yrcRoot {
            yrcText = MusicParse.string(MusicParse.dictionary(root)["lyric"])
        }
        guard !yrcText.isEmpty,
              let parsed = YRCParser.parse(yrcText),
              !parsed.isEmpty else {
            return nil
        }
        return parsed
    }

    /// Download Kugou's encrypted KRC and parse its real per-word timings.
    private func kugouKRCLyrics(_ track: MusicInfo) async -> Lyrics? {
        guard track.source == "kg" else { return nil }
        let hash = track.meta["hash"]?.stringValue ?? ""
        guard !hash.isEmpty else { return nil }
        let searchURL = try? makeURL("https://krcs.kugou.com/search", [
            ("ver", "1"), ("man", "yes"), ("client", "mobi"),
            ("keyword", ""), ("duration", ""), ("hash", hash)
        ])
        guard let searchURL,
              let search = try? await fetchJSON(searchURL),
              let candidate = MusicParse.objects(search["candidates"]).first else {
            return nil
        }
        let id = MusicParse.string(candidate["id"])
        let accessKey = MusicParse.string(candidate["accesskey"])
        guard !id.isEmpty, !accessKey.isEmpty else { return nil }
        guard let downloadURL = try? makeURL("https://lyrics.kugou.com/download", [
            ("ver", "1"), ("client", "pc"), ("id", id),
            ("accesskey", accessKey), ("fmt", "krc"), ("charset", "utf8")
        ]),
              let download = try? await fetchJSON(downloadURL) else {
            return nil
        }
        let content = MusicParse.string(download["content"])
        guard let data = Data(base64Encoded: content),
              let raw = LyricCrypto.decryptKRC(data),
              let parsed = KRCParser.parse(raw),
              !parsed.isEmpty else {
            return nil
        }
        return parsed
    }

    /// Cross-platform KRC search for platforms without their own enhanced
    /// lyric format. Returns nil when no confident title/singer match exists.
    private func kugouKRCSearchLyrics(for track: MusicInfo) async -> Lyrics? {
        let title = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let singer = track.singer.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = [title, singer].filter { !$0.isEmpty }.joined(separator: " ")

        guard let searchURL = try? makeURL("https://krcs.kugou.com/search", [
            ("ver", "1"), ("man", "yes"), ("client", "mobi"),
            ("keyword", keyword), ("duration", ""), ("hash", "")
        ]),
              let search = try? await fetchJSON(searchURL) else {
            return nil
        }
        let candidates = MusicParse.objects(search["candidates"])
        guard !candidates.isEmpty else { return nil }

        let normalizedTitle = normalize(title)
        let normalizedSinger = normalize(singer)
        let matched = candidates.first { item in
            let itemTitle = normalize(MusicParse.string(item["song"]))
            let itemSinger = normalize(MusicParse.string(item["singer"]))
            let titleOK = itemTitle == normalizedTitle
                || itemTitle.contains(normalizedTitle)
                || normalizedTitle.contains(itemTitle)
            let singerOK = normalizedSinger.isEmpty
                || itemSinger.contains(normalizedSinger)
                || normalizedSinger.contains(itemSinger)
            return titleOK && singerOK
        }
        guard let candidate = matched ?? candidates.first else { return nil }

        let id = MusicParse.string(candidate["id"])
        let accessKey = MusicParse.string(candidate["accesskey"])
        guard !id.isEmpty, !accessKey.isEmpty,
              let downloadURL = try? makeURL("https://lyrics.kugou.com/download", [
                ("ver", "1"), ("client", "pc"), ("id", id),
                ("accesskey", accessKey), ("fmt", "krc"), ("charset", "utf8")
              ]),
              let download = try? await fetchJSON(downloadURL) else {
            return nil
        }
        let content = MusicParse.string(download["content"])
        guard let data = Data(base64Encoded: content),
              let raw = LyricCrypto.decryptKRC(data),
              let parsed = KRCParser.parse(raw),
              !parsed.isEmpty else {
            return nil
        }
        return parsed
    }

    // MARK: - HTTP

    private func makeURL(_ base: String, _ query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw LyricsError.badURL }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw LyricsError.badURL }
        return url
    }

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw LyricsError.notFound
    }

    private func fetchJSON(_ url: URL, headers: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await fetchData(url, headers: headers)
        var text = String(data: data, encoding: .utf8) ?? "{}"
        // QQ's legacy lyric endpoint may wrap JSON in MusicJsonCallback(...).
        if let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"), start < end {
            text = String(text[text.index(after: start)..<end])
        }
        do {
            return try MusicParse.decode(Data(text.utf8))
        } catch {
            // Some legacy endpoints return a plain LRC document. Treat it as
            // a lyric payload; the caller can parse it directly.
            if text.contains("[") {
                return ["lyric": text]
            }
            throw LyricsError.notFound
        }
    }

    private func fetchData(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LyricsError.http(http.statusCode)
        }
        return data
    }
}

enum LyricsParser {
    private static let timeTag = try! NSRegularExpression(
        pattern: #"\[(\d{1,4}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )

    static func parse(_ raw: String) -> Lyrics {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var timed: [(time: Double, order: Int, text: String)] = []
        var plain: [String] = []
        var order = 0

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = timeTag.matches(in: line, options: [], range: range)

            if matches.isEmpty {
                // Drop LRC metadata such as [ti:...], [ar:...], [by:...].
                if !line.hasPrefix("[") { plain.append(line) }
                continue
            }

            let text = MusicParse.htmlDecode(
                timeTag.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")
                    .trimmingCharacters(in: .whitespaces)
            )
            guard !text.isEmpty else { continue }

            for match in matches {
                let minutes = Int(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Int(ns.substring(with: match.range(at: 2))) ?? 0
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: match.range(at: 3))
                    if let value = Double(digits) {
                        fraction = value / pow(10, Double(digits.count))
                    }
                }
                timed.append((Double(minutes * 60 + seconds) + fraction, order, text))
                order += 1
            }
        }

        if !timed.isEmpty {
            timed.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
            let lines = timed.enumerated().map { index, item -> LyricLine in
                let next = timed.indices.contains(index + 1) ? timed[index + 1].time : nil
                let times = Self.wordTimings(for: item.text, start: item.time, end: next)
                let characters = Array(item.text)
                var syllables: [LyricSyllable] = []
                if times.count == characters.count {
                    for charIndex in characters.indices {
                        let start = times[charIndex]
                        let end = charIndex + 1 < times.count
                            ? times[charIndex + 1]
                            : (next ?? start + 0.35)
                        syllables.append(LyricSyllable(
                            text: String(characters[charIndex]),
                            start: start,
                            end: end
                        ))
                    }
                }
                return LyricLine(
                    id: index,
                    time: item.time,
                    text: item.text,
                    wordTimes: times,
                    endTime: next,
                    syllables: syllables
                )
            }
            return Lyrics(lines: lines, isSynced: true)
        }

        let lines = plain.enumerated().map { index, text in
            LyricLine(id: index, time: nil, text: text)
        }
        return Lyrics(lines: lines, isSynced: false)
    }

    /// Synthesizes smooth per-character timings by distributing the line
    /// duration across its characters (weighted: CJK/full-width count double).
    /// Real enhanced formats (krc/yrc) would replace this when available.
    private static func wordTimings(for text: String, start: Double, end: Double?) -> [Double] {
        guard start.isFinite else { return [] }
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        // For plain LRC the gap to the next line can contain a long
        // instrumental break. Cap the synthetic duration to a realistic
        // singing time so karaoke does not crawl through the whole gap.
        let maximum = max(2.0, Double(characters.count) * 0.32)
        let duration: Double
        if let end = end, end > start, end.isFinite {
            duration = min(end - start, maximum)
        } else {
            duration = min(3.2, maximum)
        }
        let weights = characters.map { character -> Double in
            let scalar = character.unicodeScalars.first
            if let scalar, (scalar.value >= 0x2E80 && scalar.value <= 0x9FFF)
                || (scalar.value >= 0xFF00 && scalar.value <= 0xFFEF)
                || (scalar.value >= 0x3000 && scalar.value <= 0x303F) {
                return 1.6
            }
            return character == " " ? 0.35 : 1.0
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        var offsets: [Double] = []
        var accumulated = 0.0
        for weight in weights {
            offsets.append(start + accumulated / total * duration)
            accumulated += weight
        }
        return offsets
    }
}

/// Parser for NetEase's enhanced yrc format (word/character timed lyrics):
/// `[start,duration](charStart,charDur,0)char(charStart,charDur,0)char...`
/// Times are milliseconds. Metadata header lines ([start,start]) are dropped.
enum YRCParser {
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\[(-?\d+),(-?\d+)\]\((\d+),(\d+),\d+\)(.*)$"#
    )
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"\((\d+),(\d+),\d+\)([^()]*)"#
    )

    static func parse(_ raw: String) -> Lyrics? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        struct Item {
            var start: Double
            var end: Double
            var text: String
            var offsets: [Double]
        }

        var items: [Item] = []

        for rawLine in normalized.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let match = linePattern.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length))
            guard let match else { continue }

            let startMs = Double(ns.substring(with: match.range(at: 1))) ?? 0
            let durationMs = Double(ns.substring(with: match.range(at: 2))) ?? 0
            let start = startMs / 1000
            let end = (startMs + durationMs) / 1000

            let body = ns.substring(with: match.range(at: 5))
            let bodyNS = body as NSString
            let words = wordPattern.matches(in: body, options: [], range: NSRange(location: 0, length: bodyNS.length))

            var text = ""
            var offsets: [Double] = []
            var syllables: [LyricSyllable] = []
            for word in words {
                let wordStartMs = Double(bodyNS.substring(with: word.range(at: 1))) ?? startMs
                let wordDurationMs = Double(bodyNS.substring(with: word.range(at: 2))) ?? 0
                let wordText = bodyNS.substring(with: word.range(at: 3))

                // Keep the real token window. The per-character array is only
                // a fallback for older renderers; the karaoke layer uses the
                // token's exact start/end and measured width.
                let characters = Array(wordText)
                let wordStart = wordStartMs / 1000
                let wordDuration = max(wordDurationMs / 1000, 0.001)
                for (charIndex, _) in characters.enumerated() {
                    let fraction = Double(charIndex) / Double(max(characters.count, 1))
                    offsets.append(wordStart + fraction * wordDuration)
                }
                let tokenText = MusicParse.htmlDecode(wordText)
                if !tokenText.isEmpty {
                    syllables.append(LyricSyllable(text: tokenText, start: wordStart, end: wordStart + wordDuration))
                }
                text += wordText
            }

            let clean = MusicParse.htmlDecode(text.trimmingCharacters(in: .whitespaces))
            guard !clean.isEmpty else { continue }
            // yrc metadata header rows are `[0,0](...)`; real lyric lines have
            // a non-zero duration (a line at 0:00 is valid).
            guard durationMs > 0 else { continue }
            let joinedTokens = syllables.map(\.text).joined()
            items.append(Item(
                start: start,
                end: end,
                text: clean,
                offsets: offsets,
                syllables: joinedTokens == clean ? syllables : []
            ))
        }

        guard items.count >= 2 else { return nil } // a real song has more than headers

        // Rebuild each line with word offsets strictly aligned to text
        // characters; fall back to weighted distribution when counts differ.
        var lines: [LyricLine] = []
        for (index, item) in items.enumerated() {
            let characters = Array(item.text)
            var times: [Double] = []
            if item.offsets.count == characters.count {
                times = item.offsets
            } else {
                // Redistribute the real line duration across characters.
                let duration = max(item.end - item.start, 0.4)
                let weights = characters.map { character -> Double in
                    let scalar = character.unicodeScalars.first
                    if let scalar, (scalar.value >= 0x2E80 && scalar.value <= 0x9FFF)
                        || (scalar.value >= 0xFF00 && scalar.value <= 0xFFEF) {
                        return 1.6
                    }
                    return character == " " ? 0.35 : 1.0
                }
                let total = weights.reduce(0, +)
                var accumulated = 0.0
                for weight in weights {
                    times.append(item.start + accumulated / max(total, 0.001) * duration)
                    accumulated += weight
                }
            }
            let joinedTokens = item.syllables.map(\.text).joined()
            lines.append(LyricLine(
                id: index,
                time: item.start,
                text: item.text,
                wordTimes: times,
                endTime: items.indices.contains(index + 1) ? items[index + 1].start : item.end,
                syllables: joinedTokens == item.text ? item.syllables : []
            ))
        }

        return Lyrics(lines: lines, isSynced: true, isWordTimed: true)
    }
}
