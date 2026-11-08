import Foundation

extension NativeMusicAPI {
    // MARK: - Leaderboards

    func rankKW(_ boardID: String, page: Int) async throws -> OnlinePage {
        let url = try makeURL("http://kbangserver.kuwo.cn/ksong.s", [
            ("from", "pc"), ("fmt", "json"), ("pn", String(page - 1)), ("rn", "100"),
            ("type", "bang"), ("data", "content"), ("id", boardID),
            ("show_copyright_off", "0"), ("pcmp4", "1"), ("isbang", "1")
        ])
        let body = try await getJSON(url)
        let raw = MusicParse.objects(body["musiclist"])
        var tracks: [MusicInfo] = []
        for item in raw {
            let songID = MusicParse.string(item["id"])
            guard !songID.isEmpty else { continue }
            let duration = MusicParse.int(item["song_duration"]) != 0
                ? MusicParse.int(item["song_duration"])
                : MusicParse.int(item["duration"])
            tracks.append(makeTrack(
                source: "kw",
                songID: songID,
                name: MusicParse.htmlDecode(MusicParse.string(item["name"])),
                singer: MusicParse.htmlDecode(MusicParse.string(item["artist"])).replacingOccurrences(of: "&", with: "、"),
                albumName: MusicParse.htmlDecode(MusicParse.string(item["album"])),
                albumID: MusicParse.string(item["albumid"]),
                interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
                qualities: [ParsedQuality(type: "128k", size: nil)]
            ))
        }
        let total = MusicParse.int(body["num"]) != 0 ? MusicParse.int(body["num"]) : tracks.count
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * 100 < total)
    }

    func rankKG(_ boardID: String, page: Int) async throws -> OnlinePage {
        let url = try makeURL("http://mobilecdnbj.kugou.com/api/v3/rank/song", [
            ("version", "9108"), ("ranktype", "1"), ("plat", "0"), ("pagesize", "100"),
            ("area_code", "1"), ("page", String(page)), ("rankid", boardID),
            ("with_res_tag", "0"), ("show_portrait_mv", "1")
        ])
        let body = try await getJSON(url)
        let data = MusicParse.dictionary(body["data"])
        let total = MusicParse.int(data["total"])
        var tracks: [MusicInfo] = []
        for item in MusicParse.objects(data["info"]) {
            let songID = MusicParse.string(item["audio_id"])
            let hash = MusicParse.string(item["hash"])
            guard !songID.isEmpty, !hash.isEmpty else { continue }
            var qualities: [ParsedQuality] = []
            if MusicParse.int64(item["filesize"]) != 0 {
                qualities.append(ParsedQuality(type: "128k", size: MusicParse.size(MusicParse.int64(item["filesize"])), extra: ["hash": hash]))
            }
            if MusicParse.int64(item["320filesize"]) != 0 {
                qualities.append(ParsedQuality(type: "320k", size: MusicParse.size(MusicParse.int64(item["320filesize"])), extra: ["hash": MusicParse.string(item["320hash"])]))
            }
            if MusicParse.int64(item["sqfilesize"]) != 0 {
                qualities.append(ParsedQuality(type: "flac", size: MusicParse.size(MusicParse.int64(item["sqfilesize"])), extra: ["hash": MusicParse.string(item["sqhash"])]))
            }
            if MusicParse.int64(item["filesize_super"]) != 0 {
                qualities.append(ParsedQuality(type: "flac24bit", size: MusicParse.size(MusicParse.int64(item["filesize_super"])), extra: ["hash": MusicParse.string(item["hash_super"])]))
            }
            let singers = MusicParse.objects(item["authors"]).map { MusicParse.string($0["author_name"]) }
            let duration = MusicParse.int(item["duration"])
            tracks.append(makeTrack(
                source: "kg",
                songID: songID,
                name: MusicParse.htmlDecode(MusicParse.string(item["songname"])),
                singer: MusicParse.htmlDecode(MusicParse.singer(names: singers)),
                albumName: MusicParse.htmlDecode(MusicParse.string(item["remark"])),
                albumID: MusicParse.string(item["album_id"]),
                interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
                qualities: qualities,
                extra: ["hash": .string(hash)],
                identity: "\(songID)_\(hash)"
            ))
        }
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * 100 < total)
    }

    func rankWY(_ boardID: String, page: Int) async throws -> OnlinePage {
        try await wyPlaylistTracks(id: boardID, page: page)
    }

    func rankMG(_ boardID: String, page: Int) async throws -> OnlinePage {
        let url = try makeURL("https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/querycontentbyId.do", [
            ("columnId", boardID), ("needAll", "0")
        ])
        let body = try await getJSON(url, headers: [
            "Referer": "https://app.c.nf.migu.cn/",
            "User-Agent": "Mozilla/5.0 (Linux; Android 5.1.1; Nexus 6 Build/LYZ28E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/59.0.3071.115 Mobile Safari/537.36",
            "channel": "0146921"
        ])
        guard MusicParse.string(body["code"]) == "000000" else {
            throw MusicAPIError.invalidResponse(MusicParse.string(body["info"]))
        }
        let contents = MusicParse.objects(MusicParse.dictionary(body["columnInfo"])["contents"])
        var tracks: [MusicInfo] = []
        for entry in contents {
            let item = MusicParse.dictionary(entry["objectInfo"])
            guard let track = makeMGTrack(item, requireAudioFormats: false) else { continue }
            tracks.append(track)
        }
        return OnlinePage(items: tracks, page: page, total: tracks.count, hasMore: false)
    }

    func rankTX(_ boardID: String, page: Int) async throws -> OnlinePage {
        throw MusicAPIError.unsupported("QQ 排行榜详情")
    }

    // MARK: - Playlists

    func playlistsKW(page: Int) async throws -> [OnlinePlaylist] {
        let url = try makeURL("http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList", [
            ("loginUid", "0"), ("loginSid", "0"), ("appUid", "76039576"),
            ("pn", String(page)), ("rn", "36"), ("order", "hot")
        ])
        let body = try await getJSON(url)
        let data = MusicParse.dictionary(body["data"])
        return MusicParse.objects(data["data"]).compactMap { item in
            let id = MusicParse.string(item["id"])
            guard !id.isEmpty else { return nil }
            return OnlinePlaylist(
                id: id,
                name: MusicParse.htmlDecode(MusicParse.string(item["name"])),
                author: MusicParse.string(item["uname"]),
                artworkURL: URL(string: MusicParse.string(item["img"])),
                trackCount: Int(MusicParse.string(item["total"])),
                source: "kw"
            )
        }
    }

    func playlistsTX(page: Int) async throws -> [OnlinePlaylist] {
        let dataObject: [String: Any] = [
            "playlist": [
                "method": "get_category_content",
                "param": ["titleid": 3, "caller": "0", "category_id": 3, "size": 36, "page": page - 1, "use_page": 1],
                "module": "playlist.PlayListCategoryServer"
            ]
        ]
        let dataData = try JSONSerialization.data(withJSONObject: dataObject)
        let dataText = String(data: dataData, encoding: .utf8) ?? "{}"
        let url = try makeURL("https://u.y.qq.com/cgi-bin/musicu.fcg", [
            ("loginUin", "0"), ("hostUin", "0"), ("format", "json"), ("inCharset", "utf-8"),
            ("outCharset", "utf-8"), ("notice", "0"), ("platform", "wk_v15.json"),
            ("needNewCode", "0"), ("data", dataText)
        ])
        let body = try await getJSON(url)
        let content = MusicParse.dictionary(MusicParse.dictionary(MusicParse.dictionary(body["playlist"])["data"])["content"])
        return MusicParse.objects(content["v_item"]).compactMap { item in
            let basic = MusicParse.dictionary(item["basic"])
            let id = MusicParse.string(basic["tid"])
            guard !id.isEmpty else { return nil }
            let cover = MusicParse.dictionary(basic["cover"])
            let creator = MusicParse.dictionary(basic["creator"])
            return OnlinePlaylist(
                id: id,
                name: MusicParse.string(basic["title"]),
                author: MusicParse.string(creator["nick"]),
                artworkURL: URL(string: MusicParse.string(cover["default_url"])),
                trackCount: MusicParse.int(basic["song_cnt"]),
                source: "tx"
            )
        }
    }

    func playlistsWY(page: Int) async throws -> [OnlinePlaylist] {
        let url = try makeURL("https://music.163.com/api/playlist/list", [
            ("cat", "全部"), ("order", "hot"), ("offset", String((page - 1) * 30)),
            ("total", "true"), ("limit", "30")
        ])
        let body = try await getJSON(url)
        return MusicParse.objects(body["playlists"]).compactMap { item in
            let id = MusicParse.string(item["id"])
            guard !id.isEmpty else { return nil }
            let creator = MusicParse.dictionary(item["creator"])
            return OnlinePlaylist(
                id: id,
                name: MusicParse.string(item["name"]),
                author: MusicParse.string(creator["nickname"]),
                artworkURL: URL(string: MusicParse.string(item["coverImgUrl"])),
                trackCount: MusicParse.int(item["trackCount"]),
                source: "wy"
            )
        }
    }

    func playlistsMG(page: Int) async throws -> [OnlinePlaylist] {
        let url = try makeURL("https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0", [
            ("templateVersion", "2"), ("pageNo", String(page))
        ])
        let body = try await getJSON(url)
        var found: [[String: Any]] = []
        collectMGPlaylistObjects(body["data"], into: &found)
        var seen = Set<String>()
        return found.compactMap { item in
            let log = MusicParse.dictionary(item["logEvent"])
            let id = MusicParse.string(log["contentId"])
            guard !id.isEmpty, !seen.contains(id) else { return nil }
            seen.insert(id)
            return OnlinePlaylist(
                id: id,
                name: MusicParse.string(log["contentName"]).isEmpty ? MusicParse.string(item["txt"]) : MusicParse.string(log["contentName"]),
                author: nil,
                artworkURL: URL(string: MusicParse.string(item["img"])),
                trackCount: nil,
                source: "mg"
            )
        }
    }

    func playlistsKG(page: Int) async throws -> [OnlinePlaylist] {
        throw MusicAPIError.unsupported("酷狗歌单")
    }

    private func collectMGPlaylistObjects(_ value: Any?, into result: inout [[String: Any]]) {
        if let dictionary = value as? [String: Any] {
            let log = MusicParse.dictionary(dictionary["logEvent"])
            if MusicParse.string(log["contentType"]) == "2021" || MusicParse.string(log["resourceType"]) == "2021" {
                result.append(dictionary)
            }
            for child in dictionary.values { collectMGPlaylistObjects(child, into: &result) }
        } else if let array = value as? [Any] {
            for child in array { collectMGPlaylistObjects(child, into: &result) }
        }
    }

    // MARK: - Playlist detail

    func playlistDetailKW(_ id: String, page: Int) async throws -> OnlinePage {
        let url = try makeURL("http://nplserver.kuwo.cn/pl.svc", [
            ("op", "getlistinfo"), ("pid", id), ("pn", String(page - 1)), ("rn", "1000"),
            ("encode", "utf8"), ("keyset", "pl2012"), ("identity", "kuwo"),
            ("pcmp4", "1"), ("vipver", "MUSIC_9.0.5.0_W1"), ("newver", "1")
        ])
        let body = try await getJSON(url)
        let raw = MusicParse.objects(body["musiclist"])
        var tracks: [MusicInfo] = []
        for item in raw {
            let songID = MusicParse.string(item["id"])
            guard !songID.isEmpty else { continue }
            let duration = MusicParse.int(item["song_duration"]) != 0
                ? MusicParse.int(item["song_duration"])
                : MusicParse.int(item["duration"])
            let info = MusicParse.string(item["N_MINFO"]).isEmpty ? MusicParse.string(item["MINFO"]) : MusicParse.string(item["N_MINFO"])
            tracks.append(makeTrack(
                source: "kw",
                songID: songID,
                name: MusicParse.htmlDecode(MusicParse.string(item["name"])),
                singer: MusicParse.htmlDecode(MusicParse.string(item["artist"])).replacingOccurrences(of: "&", with: "、"),
                albumName: MusicParse.htmlDecode(MusicParse.string(item["album"])),
                albumID: MusicParse.string(item["albumid"]),
                interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
                qualities: parseKWQualities(info)
            ))
        }
        let total = MusicParse.int(body["num"]) != 0 ? MusicParse.int(body["num"]) : tracks.count
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * 1000 < total)
    }

    func playlistDetailTX(_ id: String, page: Int) async throws -> OnlinePage {
        let url = try makeURL("https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg", [
            ("type", "1"), ("json", "1"), ("utf8", "1"), ("onlysong", "0"), ("new_format", "1"),
            ("disstid", id), ("loginUin", "0"), ("hostUin", "0"), ("format", "json"),
            ("inCharset", "utf8"), ("outCharset", "utf-8"), ("notice", "0"),
            ("platform", "yqq.json"), ("needNewCode", "0")
        ])
        let body = try await getJSON(url, headers: ["Referer": "https://y.qq.com/"])
        let playlist = MusicParse.objects(body["cdlist"]).first ?? [:]
        let raw = MusicParse.objects(playlist["songlist"])
        var tracks: [MusicInfo] = []
        for item in raw {
            guard let track = makeTXTrack(item) else { continue }
            tracks.append(track)
        }
        let total = MusicParse.int(playlist["total_song_num"]) != 0 ? MusicParse.int(playlist["total_song_num"]) : tracks.count
        return OnlinePage(items: tracks, page: page, total: total, hasMore: false)
    }

    func playlistDetailWY(_ id: String, page: Int) async throws -> OnlinePage {
        try await wyPlaylistTracks(id: id, page: page)
    }

    func wyPlaylistTracks(id: String, page: Int) async throws -> OnlinePage {
        let url = try makeURL("https://music.163.com/api/v6/playlist/detail", [("id", id)])
        let body = try await getJSON(url)
        guard MusicParse.int(body["code"]) == 200 else {
            throw MusicAPIError.invalidResponse("网易返回 code \(MusicParse.int(body["code"]))")
        }
        let playlist = MusicParse.dictionary(body["playlist"])
        let privileges = MusicParse.objects(playlist["privileges"])
        var privilegeMap: [String: [String: Any]] = [:]
        for privilege in privileges {
            privilegeMap[MusicParse.string(privilege["id"])] = privilege
        }
        let raw = MusicParse.objects(playlist["tracks"])
        var tracks: [MusicInfo] = []
        for item in raw {
            let songID = MusicParse.string(item["id"])
            guard !songID.isEmpty else { continue }
            let artists = MusicParse.objects(item["ar"]).isEmpty ? MusicParse.objects(item["artists"]) : MusicParse.objects(item["ar"])
            let album = MusicParse.dictionary(item["al"]).isEmpty ? MusicParse.dictionary(item["album"]) : MusicParse.dictionary(item["al"])
            let durationMS = MusicParse.double(item["dt"]) != 0 ? MusicParse.double(item["dt"]) : MusicParse.double(item["duration"])
            var privilege = MusicParse.dictionary(item["privilege"])
            if privilege.isEmpty { privilege = privilegeMap[songID] ?? [:] }
            var qualities: [ParsedQuality] = []
            if MusicParse.string(privilege["maxBrLevel"]) == "hires" {
                let size = MusicParse.int64(MusicParse.dictionary(item["hr"])["size"])
                qualities.append(ParsedQuality(type: "flac24bit", size: size > 0 ? MusicParse.size(size) : nil))
            }
            let maxbr = MusicParse.int(privilege["maxbr"])
            if maxbr >= 999000 {
                qualities.append(ParsedQuality(type: "flac", size: wySize(item["sq"])))
                qualities.append(ParsedQuality(type: "320k", size: wySize(item["h"])))
                qualities.append(ParsedQuality(type: "128k", size: wySize(item["l"])))
            } else if maxbr >= 320000 {
                qualities.append(ParsedQuality(type: "320k", size: wySize(item["h"])))
                qualities.append(ParsedQuality(type: "128k", size: wySize(item["l"])))
            } else {
                qualities.append(ParsedQuality(type: "128k", size: wySize(item["l"])))
            }
            let duration = Int(durationMS / 1000)
            tracks.append(makeTrack(
                source: "wy",
                songID: songID,
                name: MusicParse.string(item["name"]),
                singer: MusicParse.singer(names: artists.map { MusicParse.string($0["name"]) }),
                albumName: MusicParse.string(album["name"]),
                albumID: MusicParse.string(album["id"]),
                interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
                picURL: MusicParse.string(album["picUrl"]),
                qualities: qualities
            ))
        }
        let total = MusicParse.int(playlist["trackCount"]) != 0 ? MusicParse.int(playlist["trackCount"]) : tracks.count
        return OnlinePage(items: tracks, page: page, total: total, hasMore: false)
    }

    func playlistDetailMG(_ id: String, page: Int) async throws -> OnlinePage {
        let url = try makeURL("https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0", [
            ("pageNo", String(page)), ("pageSize", "100"), ("playlistId", id)
        ])
        let body = try await getJSON(url, headers: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1"])
        guard MusicParse.string(body["code"]) == "000000" else {
            throw MusicAPIError.invalidResponse(MusicParse.string(body["info"]))
        }
        let data = MusicParse.dictionary(body["data"])
        let raw = MusicParse.objects(data["songList"])
        var tracks: [MusicInfo] = []
        for item in raw {
            guard let track = makeMGTrack(item, requireAudioFormats: true) else { continue }
            tracks.append(track)
        }
        let total = MusicParse.int(data["totalCount"]) != 0 ? MusicParse.int(data["totalCount"]) : tracks.count
        return OnlinePage(items: tracks, page: page, total: total, hasMore: page * 100 < total)
    }

    func playlistDetailKG(_ id: String, page: Int) async throws -> OnlinePage {
        throw MusicAPIError.unsupported("酷狗歌单")
    }

    // MARK: - Shared track builders

    private func makeTXTrack(_ item: [String: Any]) -> MusicInfo? {
        let file = MusicParse.dictionary(item["file"])
        let mediaMid = MusicParse.string(file["media_mid"])
        let songMid = MusicParse.string(item["mid"])
        guard !mediaMid.isEmpty, !songMid.isEmpty else { return nil }
        let album = MusicParse.dictionary(item["album"])
        let albumMid = MusicParse.string(album["mid"])
        let singers = MusicParse.objects(item["singer"]).map { MusicParse.string($0["name"]) }
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
        var extra: [String: JSONValue] = [
            "strMediaMid": .string(mediaMid),
            "albumMid": .string(albumMid)
        ]
        if let songID = item["id"] { extra["id"] = .string(MusicParse.string(songID)) }
        let duration = MusicParse.int(item["interval"])
        return makeTrack(
            source: "tx",
            songID: songMid,
            name: MusicParse.htmlDecode(MusicParse.string(item["name"])),
            singer: MusicParse.singer(names: singers),
            albumName: MusicParse.string(album["name"]),
            albumID: albumMid,
            interval: duration > 0 ? MusicParse.formatPlayTime(duration) : nil,
            picURL: albumMid.isEmpty ? "" : "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMid).jpg",
            qualities: qualities,
            extra: extra
        )
    }

    private func makeMGTrack(_ item: [String: Any], requireAudioFormats: Bool) -> MusicInfo? {
        let songID = MusicParse.string(item["songId"])
        var copyrightID = MusicParse.string(item["copyrightId"])
        if copyrightID.isEmpty { copyrightID = MusicParse.string(item["contentId"]) }
        guard !songID.isEmpty else { return nil }
        let singers = MusicParse.objects(item["singerList"]).map { MusicParse.string($0["name"]) }
        let singerText = singers.isEmpty ? MusicParse.string(item["singer"]) : MusicParse.singer(names: singers)
        var qualities: [ParsedQuality] = []
        let formats = MusicParse.objects(item["audioFormats"]).isEmpty ? MusicParse.objects(item["newRateFormats"]) : MusicParse.objects(item["audioFormats"])
        if requireAudioFormats && formats.isEmpty { return nil }
        for format in formats {
            let type: String?
            switch MusicParse.string(format["formatType"]) {
            case "PQ": type = "128k"
            case "HQ": type = "320k"
            case "SQ": type = "flac"
            case "ZQ", "ZQ24": type = "flac24bit"
            default: type = nil
            }
            if let type {
                let size = MusicParse.int64(format["asize"]) != 0 ? MusicParse.int64(format["asize"]) : MusicParse.int64(format["isize"])
                let fallback = MusicParse.int64(format["size"]) != 0 ? MusicParse.int64(format["size"]) : MusicParse.int64(format["androidSize"])
                qualities.append(ParsedQuality(type: type, size: MusicParse.size(size != 0 ? size : fallback)))
            }
        }
        var pic = MusicParse.string(item["img3"])
        if pic.isEmpty { pic = MusicParse.string(item["img2"]) }
        if pic.isEmpty { pic = MusicParse.string(item["img1"]) }
        if pic.isEmpty, let first = MusicParse.objects(item["albumImgs"]).first { pic = MusicParse.string(first["img"]) }
        if !pic.isEmpty, !pic.hasPrefix("http") { pic = "http://d.musicapp.migu.cn" + pic }
        var interval = MusicParse.string(item["length"])
        if interval.isEmpty {
            let duration = MusicParse.int(item["duration"])
            if duration > 0 { interval = MusicParse.formatPlayTime(duration) }
        }
        return makeTrack(
            source: "mg",
            songID: songID,
            name: MusicParse.htmlDecode(MusicParse.string(item["songName"]).isEmpty ? MusicParse.string(item["name"]) : MusicParse.string(item["songName"])),
            singer: MusicParse.htmlDecode(singerText),
            albumName: MusicParse.string(item["album"]),
            albumID: MusicParse.string(item["albumId"]),
            interval: interval.isEmpty ? nil : interval,
            picURL: pic,
            qualities: qualities,
            extra: [
                "copyrightId": .string(copyrightID),
                "lrcUrl": .string(MusicParse.string(item["lrcUrl"])),
                "mrcUrl": .string(MusicParse.string(item["mrcUrl"])),
                "trcUrl": .string(MusicParse.string(item["trcUrl"]))
            ]
        )
    }
}
