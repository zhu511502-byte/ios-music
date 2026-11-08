import Foundation

extension NativeMusicAPI {
    // MARK: - Kuwo

    func searchKW(_ query: String, page: Int, limit: Int) async throws -> OnlinePage {
        let url = try makeURL("http://search.kuwo.cn/r.s", [
            ("client", "kt"), ("all", query), ("pn", String(page - 1)), ("rn", String(limit)),
            ("uid", "794762570"), ("ver", "kwplayer_ar_9.2.2.1"), ("vipver", "1"),
            ("show_copyright_off", "1"), ("newver", "1"), ("ft", "music"), ("cluster", "0"),
            ("strategy", "2012"), ("encoding", "utf8"), ("rformat", "json"), ("vermerge", "1"),
            ("mobi", "1"), ("issubtitle", "1")
        ])
        let body = try await getJSON(url)
        let total = MusicParse.int(body["TOTAL"])
        var tracks: [MusicInfo] = []
        for item in MusicParse.objects(body["abslist"]) {
            let rawID = MusicParse.string(item["MUSICRID"])
            let songID = rawID.replacingOccurrences(of: "MUSIC_", with: "")
            guard !songID.isEmpty else { continue }
            let qualities = parseKWQualities(MusicParse.string(item["N_MINFO"]))
            let duration = MusicParse.int(item["DURATION"])
            tracks.append(makeTrack(
                source: "kw",
                songID: songID,
                name: MusicParse.htmlDecode(MusicParse.string(item["SONGNAME"])),
                singer: MusicParse.htmlDecode(MusicParse.string(item["ARTIST"])).replacingOccurrences(of: "&", with: "、"),
                albumName: MusicParse.htmlDecode(MusicParse.string(item["ALBUM"])),
                albumID: MusicParse.htmlDecode(MusicParse.string(item["ALBUMID"])),
                interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
                qualities: qualities
            ))
        }
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * limit < total)
    }

    func parseKWQualities(_ text: String) -> [ParsedQuality] {
        guard !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: "level:(\\w+),bitrate:(\\d+),format:(\\w+),size:([\\w.]+)") else {
            return []
        }
        var result: [ParsedQuality] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let bitrateRange = Range(match.range(at: 2), in: text),
                  let sizeRange = Range(match.range(at: 4), in: text) else { continue }
            let bitrate = String(text[bitrateRange])
            let size = String(text[sizeRange])
            let type: String?
            switch bitrate {
            case "4000": type = "flac24bit"
            case "2000": type = "flac"
            case "320": type = "320k"
            case "128": type = "128k"
            default: type = nil
            }
            if let type { result.append(ParsedQuality(type: type, size: size)) }
        }
        return Array(result.reversed())
    }

    // MARK: - Kugou

    func searchKG(_ query: String, page: Int, limit: Int) async throws -> OnlinePage {
        let url = try makeURL("https://songsearch.kugou.com/song_search_v2", [
            ("keyword", query), ("page", String(page)), ("pagesize", String(limit)),
            ("userid", "0"), ("clientver", ""), ("platform", "WebFilter"), ("filter", "2"),
            ("iscorrection", "1"), ("privilege_filter", "0"), ("area_code", "1")
        ])
        let body = try await getJSON(url)
        let data = MusicParse.dictionary(body["data"])
        let total = MusicParse.int(data["total"])
        var tracks: [MusicInfo] = []
        var seen = Set<String>()
        for item in MusicParse.objects(data["lists"]) {
            appendKGTrack(item, to: &tracks, seen: &seen)
            for child in MusicParse.objects(item["Grp"]) {
                appendKGTrack(child, to: &tracks, seen: &seen)
            }
        }
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * limit < total)
    }

    private func appendKGTrack(_ item: [String: Any], to tracks: inout [MusicInfo], seen: inout Set<String>) {
        let songID = MusicParse.string(item["Audioid"])
        let hash = MusicParse.string(item["FileHash"])
        guard !songID.isEmpty, !hash.isEmpty else { return }
        let key = songID + hash
        guard !seen.contains(key) else { return }
        seen.insert(key)

        var qualities: [ParsedQuality] = []
        if MusicParse.int64(item["FileSize"]) != 0 {
            qualities.append(ParsedQuality(type: "128k", size: MusicParse.size(MusicParse.int64(item["FileSize"])), extra: ["hash": MusicParse.string(item["FileHash"])]))
        }
        if MusicParse.int64(item["HQFileSize"]) != 0 {
            qualities.append(ParsedQuality(type: "320k", size: MusicParse.size(MusicParse.int64(item["HQFileSize"])), extra: ["hash": MusicParse.string(item["HQFileHash"])]))
        }
        if MusicParse.int64(item["SQFileSize"]) != 0 {
            qualities.append(ParsedQuality(type: "flac", size: MusicParse.size(MusicParse.int64(item["SQFileSize"])), extra: ["hash": MusicParse.string(item["SQFileHash"])]))
        }
        if MusicParse.int64(item["ResFileSize"]) != 0 {
            qualities.append(ParsedQuality(type: "flac24bit", size: MusicParse.size(MusicParse.int64(item["ResFileSize"])), extra: ["hash": MusicParse.string(item["ResFileHash"])]))
        }

        let singers = MusicParse.objects(item["Singers"]).map { MusicParse.string($0["name"]) }
        let suffix = MusicParse.string(item["Suffix"])
        let baseName = MusicParse.string(item["OriSongName"])
        let name = suffix.isEmpty ? baseName : "\(baseName) \(suffix)"
        let duration = MusicParse.int(item["Duration"])
        let track = makeTrack(
            source: "kg",
            songID: songID,
            name: MusicParse.htmlDecode(name),
            singer: MusicParse.htmlDecode(MusicParse.singer(names: singers)),
            albumName: MusicParse.htmlDecode(MusicParse.string(item["AlbumName"])),
            albumID: MusicParse.string(item["AlbumID"]),
            interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
            qualities: qualities,
            extra: ["hash": .string(hash)],
            identity: "\(songID)_\(hash)"
        )
        tracks.append(track)
    }

    // MARK: - QQ Music

    func searchTX(_ query: String, page: Int, limit: Int) async throws -> OnlinePage {
        let payload: [String: Any] = [
            "comm": [
                "_channelid": "0", "_os_version": "6.2.9200-2", "ct": "19", "cv": "2151",
                "guid": "1F70E520B2EAA7D25E11760783C53CA9", "patch": "118",
                "psrf_access_token_expiresAt": 0, "psrf_qqaccess_token": "", "psrf_qqopenid": "",
                "psrf_qqunionid": "", "tmeAppID": "qqmusic", "tmeLoginType": 0, "uin": "0",
                "wid": "7223299733393904640"
            ],
            "music.search.SearchCgiService": [
                "module": "music.search.SearchCgiService",
                "method": "DoSearchForQQMusicDesktop",
                "param": [
                    "grp": 1, "num_per_page": limit, "page_num": page, "query": query,
                    "remoteplace": "txt.newclient.top", "search_type": 0,
                    "searchid": MusicCrypto.randomHexString(count: 32) + String(format: "%05d", Int.random(in: 0..<100000))
                ]
            ]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadText = String(data: payloadData, encoding: .utf8) ?? "{}"
        let sign = MusicCrypto.zzcSign(payloadText)
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musics.fcg?sign=\(sign)") else { throw MusicAPIError.badURL }
        let result = try await perform(url, method: "POST", headers: [
            "User-Agent": "QQMusic 14090508(android 12)",
            "Content-Type": "application/json"
        ], body: payloadData)
        guard (200..<300).contains(result.response.statusCode) else {
            throw MusicAPIError.http(result.response.statusCode)
        }
        let body = try MusicParse.decode(result.data)
        let service = MusicParse.dictionary(body["music.search.SearchCgiService"])
        let data = MusicParse.dictionary(service["data"])
        let song = MusicParse.dictionary(MusicParse.dictionary(data["body"])["song"])
        let rawList = MusicParse.objects(song["list"])
        let total = MusicParse.int(MusicParse.dictionary(data["meta"])["sum"])
        var tracks: [MusicInfo] = []
        for item in rawList {
            let file = MusicParse.dictionary(item["file"])
            let mediaMid = MusicParse.string(file["media_mid"])
            let songMid = MusicParse.string(item["mid"])
            guard !mediaMid.isEmpty, !songMid.isEmpty else { continue }
            let album = MusicParse.dictionary(item["album"])
            let albumMid = MusicParse.string(album["mid"])
            let singerNames = MusicParse.objects(item["singer"]).map { MusicParse.string($0["name"]) }
            var qualities: [ParsedQuality] = []
            if MusicParse.int64(file["size_128mp3"]) != 0 {
                qualities.append(ParsedQuality(type: "128k", size: MusicParse.size(MusicParse.int64(file["size_128mp3"]))))
            }
            if MusicParse.int64(file["size_320mp3"]) != 0 {
                qualities.append(ParsedQuality(type: "320k", size: MusicParse.size(MusicParse.int64(file["size_320mp3"]))))
            }
            if MusicParse.int64(file["size_flac"]) != 0 {
                qualities.append(ParsedQuality(type: "flac", size: MusicParse.size(MusicParse.int64(file["size_flac"]))))
            }
            if MusicParse.int64(file["size_hires"]) != 0 {
                qualities.append(ParsedQuality(type: "flac24bit", size: MusicParse.size(MusicParse.int64(file["size_hires"]))))
            }
            var pic = ""
            if albumMid.isEmpty || albumMid == "空" {
                if let first = MusicParse.objects(item["singer"]).first {
                    let singerMid = MusicParse.string(first["mid"])
                    if !singerMid.isEmpty { pic = "https://y.gtimg.cn/music/photo_new/T001R500x500M000\(singerMid).jpg" }
                }
            } else {
                pic = "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg"
            }
            let intervalSeconds = MusicParse.int(item["interval"])
            var extra: [String: JSONValue] = [
                "strMediaMid": .string(mediaMid),
                "albumMid": .string(albumMid)
            ]
            if let songID = item["id"] { extra["id"] = .string(MusicParse.string(songID)) }
            tracks.append(makeTrack(
                source: "tx",
                songID: songMid,
                name: MusicParse.htmlDecode(MusicParse.string(item["title"])),
                singer: MusicParse.singer(names: singerNames),
                albumName: MusicParse.string(album["name"]),
                albumID: albumMid,
                interval: intervalSeconds > 0 ? MusicParse.formatPlayTime(intervalSeconds) : nil,
                picURL: pic,
                qualities: qualities,
                extra: extra
            ))
        }
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * limit < total)
    }

    // MARK: - NetEase

    func searchWY(_ query: String, page: Int, limit: Int) async throws -> OnlinePage {
        let path = "/api/search/song/list/page"
        let payload: [String: Any] = [
            "keyword": query, "needCorrect": "1", "channel": "typing",
            "offset": limit * (page - 1), "scene": "normal", "total": page == 1, "limit": limit
        ]
        let body = try await wyEAPI(path: path, payload: payload)
        guard MusicParse.int(body["code"]) == 200 else {
            throw MusicAPIError.invalidResponse("网易返回 code \(MusicParse.int(body["code"]))")
        }
        let data = MusicParse.dictionary(body["data"])
        let total = MusicParse.int(data["totalCount"])
        var tracks: [MusicInfo] = []
        for resource in MusicParse.objects(data["resources"]) {
            let simple = MusicParse.dictionary(MusicParse.dictionary(resource["baseInfo"])["simpleSongData"])
            let songID = MusicParse.string(simple["id"])
            guard !songID.isEmpty else { continue }
            let artists = MusicParse.objects(simple["ar"]).map { MusicParse.string($0["name"]) }
            let album = MusicParse.dictionary(simple["al"])
            let privilege = MusicParse.dictionary(simple["privilege"])
            var qualities: [ParsedQuality] = []
            let maxLevel = MusicParse.string(privilege["maxBrLevel"])
            if maxLevel == "hires" {
                let size = MusicParse.dictionary(simple["hr"])["size"]
                qualities.append(ParsedQuality(type: "flac24bit", size: MusicParse.int64(size) > 0 ? MusicParse.size(MusicParse.int64(size)) : nil))
            }
            let maxbr = MusicParse.int(privilege["maxbr"])
            switch maxbr {
            case 999000:
                qualities.append(ParsedQuality(type: "flac", size: wySize(simple["sq"])))
                qualities.append(ParsedQuality(type: "320k", size: wySize(simple["h"])))
                qualities.append(ParsedQuality(type: "128k", size: wySize(simple["l"])))
            case 320000:
                qualities.append(ParsedQuality(type: "320k", size: wySize(simple["h"])))
                qualities.append(ParsedQuality(type: "128k", size: wySize(simple["l"])))
            default:
                qualities.append(ParsedQuality(type: "128k", size: wySize(simple["l"])))
            }
            let duration = MusicParse.int(MusicParse.double(simple["dt"]) / 1000)
            tracks.append(makeTrack(
                source: "wy",
                songID: songID,
                name: MusicParse.string(simple["name"]),
                singer: MusicParse.singer(names: artists),
                albumName: MusicParse.string(album["name"]),
                albumID: MusicParse.string(album["id"]),
                interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
                picURL: MusicParse.string(album["picUrl"]),
                qualities: qualities
            ))
        }
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * limit < total)
    }

    func wySize(_ value: Any?) -> String? {
        let size = MusicParse.int64(MusicParse.dictionary(value)["size"])
        return size > 0 ? MusicParse.size(size) : nil
    }

    func wyEAPI(path: String, payload: [String: Any]) async throws -> [String: Any] {
        let textData = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: textData, encoding: .utf8) ?? "{}"
        let message = "nobody\(path)use\(text)md5forencrypt"
        let digest = MusicCrypto.md5Hex(message)
        let plain = "\(path)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let key = Data("e82ckenh8dichen8".utf8)
        let encrypted = try MusicCrypto.aes128ECBPKCS7(Data(plain.utf8), key: key)
        let params = encrypted.map { String(format: "%02X", Int($0)) }.joined()
        guard let url = URL(string: "http://interface.music.163.com/eapi/batch") else { throw MusicAPIError.badURL }
        return try await postForm(url, fields: ["params": params], headers: [
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36",
            "origin": "https://music.163.com"
        ])
    }

    // MARK: - Migu

    func searchMG(_ query: String, page: Int, limit: Int) async throws -> OnlinePage {
        let time = String(Int64(Date().timeIntervalSince1970 * 1000))
        let deviceID = "963B7AA0D21511ED807EE5846EC87D20"
        let sign = MusicCrypto.md5Hex("\(query)6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50\(deviceID)\(time)")
        let switchJSON = "%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let urlString = "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=\(switchJSON)&pageSize=\(limit)&text=\(encodedQuery)&pageNo=\(page)&sort=0&sid=USS"
        guard let url = URL(string: urlString) else { throw MusicAPIError.badURL }
        let body = try await getJSON(url, headers: [
            "uiVersion": "A_music_3.6.1",
            "deviceId": deviceID,
            "timestamp": time,
            "sign": sign,
            "channel": "0146921",
            "User-Agent": "Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30"
        ])
        guard MusicParse.string(body["code"]) == "000000" else {
            throw MusicAPIError.invalidResponse(MusicParse.string(body["info"]))
        }
        let result = MusicParse.dictionary(body["songResultData"])
        let total = MusicParse.int(result["totalCount"])
        var tracks: [MusicInfo] = []
        var seen = Set<String>()
        for group in MusicParse.array(result["resultList"]) {
            for item in MusicParse.objects(group) {
                let songID = MusicParse.string(item["songId"])
                let copyrightID = MusicParse.string(item["copyrightId"])
                guard !songID.isEmpty, !copyrightID.isEmpty, !seen.contains(copyrightID) else { continue }
                seen.insert(copyrightID)
                let singers = MusicParse.objects(item["singerList"]).map { MusicParse.string($0["name"]) }
                var qualities: [ParsedQuality] = []
                for format in MusicParse.objects(item["audioFormats"]) {
                    let type: String?
                    switch MusicParse.string(format["formatType"]) {
                    case "PQ": type = "128k"
                    case "HQ": type = "320k"
                    case "SQ": type = "flac"
                    case "ZQ24": type = "flac24bit"
                    default: type = nil
                    }
                    if let type {
                        let size = MusicParse.int64(format["asize"]) != 0 ? MusicParse.int64(format["asize"]) : MusicParse.int64(format["isize"])
                        qualities.append(ParsedQuality(type: type, size: MusicParse.size(size)))
                    }
                }
                var pic = MusicParse.string(item["img3"])
                if pic.isEmpty { pic = MusicParse.string(item["img2"]) }
                if pic.isEmpty { pic = MusicParse.string(item["img1"]) }
                if !pic.isEmpty, !pic.hasPrefix("http") { pic = "http://d.musicapp.migu.cn" + pic }
                let duration = MusicParse.int(item["duration"])
                let track = makeTrack(
                    source: "mg",
                    songID: songID,
                    name: MusicParse.htmlDecode(MusicParse.string(item["name"])),
                    singer: MusicParse.singer(names: singers),
                    albumName: MusicParse.string(item["album"]),
                    albumID: MusicParse.string(item["albumId"]),
                    interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
                    picURL: pic,
                    qualities: qualities,
                    extra: [
                        "copyrightId": .string(copyrightID),
                        "lrcUrl": .string(MusicParse.string(item["lrcUrl"])),
                        "mrcUrl": .string(MusicParse.string(item["mrcurl"])),
                        "trcUrl": .string(MusicParse.string(item["trcUrl"]))
                    ]
                )
                tracks.append(track)
            }
        }
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * limit < total)
    }
}
