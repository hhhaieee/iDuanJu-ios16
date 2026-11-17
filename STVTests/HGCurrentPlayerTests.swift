import XCTest
import CryptoKit
@testable import STV

final class HGCurrentPlayerTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/hongguo/" + name))
    }
    private func sha(_ bytes: [UInt8]) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
    func testNativeEnvelopesAndTransforms() throws {
        struct Input: Decodable {
            var raw_query: String, record_digest: Data, factor_pb: Data, material: Data, license_id: String, aid: String
            var seconds: UInt64, gorgon_nonce: UInt16, native_gorgon_flags: UInt16
            var helios_random: UInt32, medusa_random1: UInt32, medusa_random2: UInt32, local_buffer_address: UInt64, previous_thread_state: UInt32
        }
        struct Whole: Decodable { var id: String, inputs: Input, expected_header_sha256: [String: String], expected_thread_state: UInt32 }
        struct Transform: Decodable { var branch: Int, key: Data, iv: Data, plain: Data, expected_sha256: String }
        struct Vectors: Decodable { var synthetic_only: Bool, whole: [Whole], transforms: [Transform] }
        let f = try JSONDecoder().decode(Vectors.self, from: fixture("current_crypto.json"))
        XCTAssertTrue(f.synthetic_only); XCTAssertEqual(f.whole.count, 32); XCTAssertEqual(f.transforms.count, 22)
        for v in f.whole {
            let x = v.inputs
            let got = try HGCurrentPlayer.compute(query: x.raw_query, digest: Array(x.record_digest), pb: Array(x.factor_pb), material: Array(x.material), license: x.license_id, aid: x.aid,
                seconds: x.seconds, nonce: x.gorgon_nonce, flags: x.native_gorgon_flags, heliosRandom: x.helios_random, random1: x.medusa_random1, random2: x.medusa_random2,
                local: x.local_buffer_address, previous: x.previous_thread_state)
            XCTAssertEqual(got.state, v.expected_thread_state, v.id)
            for (name, expected) in v.expected_header_sha256 { XCTAssertEqual(sha(Array(try XCTUnwrap(got.headers[name]).utf8)), expected, v.id + " " + name) }
        }
        for v in f.transforms { XCTAssertEqual(sha(try HGCurrentPlayer.transform(Array(v.plain), Array(v.key), Array(v.iv), v.branch)), v.expected_sha256) }
    }
    func testNativeFactorsAndTicketBinding() throws {
        struct Factor: Decodable { var toy_seed: Int, public_input_seed: Int, public_seconds: UInt32, output_sha256: String }
        let factors = try JSONDecoder().decode([Factor].self, from: fixture("current_factor.json"))
        XCTAssertEqual(factors.count, 48)
        for f in factors { let input = (0..<52).map { UInt8(truncatingIfNeeded: $0 * 37 + f.public_input_seed) }
            XCTAssertEqual(sha(try HGCurrentPlayer.factor(input, f.public_seconds, f.toy_seed)), f.output_sha256) }
        let pairs = [("aid", "8662"), ("device_id", "1000000000000000001"), ("version_name", "7.3.9.32"), ("ts", "stale"), ("_rticket", "stale")]
        let entropy = (0..<24).map { UInt8($0 < 20 ? $0 + 1 : 0) }
        var crossed = false
        for i in 0..<32 {
            let now: Int64 = 1794827000999 + Int64(i) * 1000
            let signed = try HGCurrentPlayer.sign(pairs: pairs, nowMillis: now, deviceID: pairs[1].1, versionName: pairs[2].1, body: Array(#"{"video_id":"synthetic-1"}"#.utf8), entropy: entropy)
            let fields = try XCTUnwrap(URLComponents(string: "https://example.com/?" + signed.query)?.queryItems)
            XCTAssertEqual(fields.filter { $0.name == "ts" }.count, 1)
            let ticket = try XCTUnwrap(Int64(try XCTUnwrap(signed.headers["x-ss-req-ticket"])))
            XCTAssertTrue(ticket >= now && ticket < now + 128)
            XCTAssertEqual(signed.headers["x-khronos"], String(ticket / 1000))
            crossed = crossed || ticket / 1000 != now / 1000
        }
        XCTAssertTrue(crossed)
    }
    func testGenreScopedFiltersAndBody() throws {
        let panel = HGPanel(rows: [HGFilterRow(type: "genre", name: "剧种", selectType: 2, items: [HGFilterOption(id: "comic_series", name: "漫剧")]),
            HGFilterRow(type: "category_dim_epoch", name: "背景", selectType: 2, items: [HGFilterOption(id: "cate_1", name: "都市")])])
        let selection = try HongguoClient.categorySelection(panel, ["comic_series", "cate_1"])
        XCTAssertEqual(selection["category_dim_epoch"], ["cate_1"])
        XCTAssertThrowsError(try HongguoClient.categorySelection(panel, ["comic_series", "cate_5022"]))
        let body = HongguoClient.categoryBody(selection: ["genre": ["short_play"]], offset: 12, session: "next", seen: ["1", "2"], panel: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["req_scene"] as? String, "default"); XCTAssertEqual(json["filter_ids"] as? String, "1,2")
    }
}
