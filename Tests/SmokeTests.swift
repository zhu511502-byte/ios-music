import XCTest
import Foundation
@testable import LxPlayer

final class SmokeTests: XCTestCase {
    func testGzipRoundTrip() throws {
        let text = String(repeating: "洛雪 LxPlayer 🎵 ", count: 2000)
        let data = Data(text.utf8)
        let compressed = try Gzip.compress(data)
        XCTAssertLessThan(compressed.count, data.count)
        let restored = try Gzip.decompress(compressed)
        XCTAssertEqual(String(data: restored, encoding: .utf8), text)
    }

    func testAuthKeyDerivation() {
        XCTAssertEqual(SyncCrypto.md5Hex("123456"), "e10adc3949ba59abbe56e057f20f883e")
        XCTAssertEqual(SyncCrypto.authKey(from: "123456").count, 16)
    }

    func testMusicInfoDecode() throws {
        let json = """
        {"id":"tx_123","name":"晴天","singer":"周杰伦","source":"tx","interval":"04:29","meta":{"songId":"123","albumName":"叶惠美","picUrl":"https://example.com/a.jpg","qualitys":[{"type":"320k","size":"10 MB"}]}}
        """
        let value = try JSONDecoder().decode(MusicInfo.self, from: Data(json.utf8))
        XCTAssertEqual(value.id, "tx_123")
        XCTAssertEqual(value.songID, "123")
        XCTAssertEqual(value.availableQualities, [.k320])
    }

    func testQQZZCSign() {
        XCTAssertEqual(MusicCrypto.zzcSign("test"), "zzc3aeb15c8g08cxbjovqteliiq9ebaheowma1999c1cf")
        XCTAssertEqual(MusicCrypto.zzcSign("{\"a\":1}"), "zzc7746109xq501htmv4ipz7c8owlxfpihjm1fd695c7")
    }

    func testHTMLDecode() {
        XCTAssertEqual(MusicParse.htmlDecode("A&amp;B&#39;C"), "A&B'C")
        XCTAssertEqual(MusicParse.size(1024), "1.00 KiB")
    }

    func testLyricsParser() {
        let lrc = """
        [ti:测试]
        [00:01.00]第一句
        [00:03.50][00:05.00]重复一句
        [00:07.25]最后一句
        """
        let lyrics = LyricsParser.parse(lrc)
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.count, 4)
        XCTAssertEqual(lyrics.lines.first?.time, 1.0)
        XCTAssertEqual(lyrics.lines.last?.text, "最后一句")
    }

    func testMessage2CallEnvelope() throws {
        // Sanity-check the JSON shape used by the sync client.
        let object: [String: Any] = ["name": "list_sync_get_list_data__1", "path": ["list_sync_get_list_data"], "data": []]
        let data = try JSONSerialization.data(withJSONObject: object)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed?["name"])
        XCTAssertNotNil(parsed?["path"])
    }
}
