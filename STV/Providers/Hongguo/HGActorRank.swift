import Foundation

// MARK: - 剧星榜 (actor ranking) — hongguo-open-player hongguo-actor.js fetchActorRankings / parseRankingPayload

struct HGRankedActor: Hashable, Identifiable {
    enum Change: Int { case up = 1, down = 2, flat = 3 }
    enum Gender: String, CaseIterable, Identifiable {
        case all, male, female
        var id: String { rawValue }
        var label: String { switch self { case .all: "全部"; case .male: "男演员"; case .female: "女演员" } }
    }
    var rank: Int
    var id: String          // actor_id_str = encrypted_celebrity_id for homepage / works
    var name: String
    var avatar: String
    var score: String       // e.g. "热度 98.2万"
    var intro: String
    var subTitles: [String] // 代表作 lines
    var change: Change
    var changeNum: Int
    var gender: Gender
    var celebrity: HGCelebrity { HGCelebrity(id: id, name: name, avatar: avatar, role: "剧星榜 No.\(rank)" + (score.isEmpty ? "" : " · " + score), intro: intro) }
}

struct HGActorRankPage {
    var actors: [HGRankedActor]
    var rankDate: String
    var hasMore: Bool
    var nextOffset: Int
    var sessionId: String
}

extension HongguoClient {
    /// Unsigned list GET on bookmall/cell/change (same cell as the drama boards, selector ranklist_series_actor).
    func actorRank(offset: Int = 0, sessionId: String = "", limit: Int = 20, startRank: Int = 0) async throws -> HGActorRankPage {
        let d = try await ensureDevice()
        let first = offset == 0
        let u = Self.urlRankCell + "background_selected_items=&category_id=0&cell_id=7470092475068071998&cell_sub_id=0" +
            "&client_req_type=2&client_template=2&filter_ids=&gender=2&limit=\(limit)&offset=\(offset)&panel_selected_items=" +
            "&selected_items=ranklist_celebrity&session_id=" + GoURL.queryEscape(first ? "" : sessionId) +
            "&sub_selected_items=ranklist_series_actor&tab_type=\(first ? 26 : 18)&unlimited_selector_change_type=0&" +
            Self.listQuery(d, Self.nowMs())
        let data = try ok(try await list(u), "剧星榜")
        let cv = J.dict(data["cell_view"])
        // Refuse a silently-substituted board (服务端可能回落到星光榜等其它子榜).
        let outer = J.arr(J.dict(J.dict(cv["cell_selector"])["outer_row"])["items"]).map(J.dict).first { J.bool($0["is_selected"]) }
        if let outer {
            let oid = J.str(outer["selector_item_id"])
            if !oid.isEmpty && oid != "ranklist_celebrity" { throw ProviderError.upstream("服务端未选中演员榜（\(oid)）") }
            let sub = J.arr(J.dict(J.dict(outer["sub_cell_selector"])["outer_row"])["items"]).map(J.dict).first { J.bool($0["is_selected"]) }
            let sid = J.str(sub?["selector_item_id"])
            if !sid.isEmpty && sid != "ranklist_series_actor" { throw ProviderError.upstream("服务端未选中剧星榜（\(sid)）") }
        }
        var date = ""
        if let s = (cv["cell_data_json"] as? String)?.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: s) as? [String: Any] { date = J.str(o["rank_list_date"]) }
        if date.isEmpty, let all = try? JSONSerialization.data(withJSONObject: data),
           let m = String(decoding: all, as: UTF8.self).range(of: #"rank_list_date\\*"\s*:\s*\\*"[^"\\]+"#, options: .regularExpression) {
            let hit = String(String(decoding: all, as: UTF8.self)[m])
            date = hit.components(separatedBy: "\"").filter { !$0.isEmpty && !$0.contains("rank_list_date") && $0.trimmingCharacters(in: CharacterSet(charactersIn: "\\: ")).count > 0 }
                .last?.trimmingCharacters(in: CharacterSet(charactersIn: "\\: ")) ?? ""
        }
        var out: [HGRankedActor] = []
        var r = startRank
        for c in J.arr(cv["cell_data"]) {
            for raw in J.arr(J.dict(c)["ugc_user_data"]) {
                let m = J.dict(raw)
                let ui = J.dict(m["user_info"]), base = J.dict(ui["base_info"])
                let id = J.str(base["actor_id_str"]), name = Self.cleanText(J.str(base["user_name"]))
                guard !id.isEmpty, !name.isEmpty else { continue }
                r += 1
                let intro = Self.cleanText(J.str(m["intro"]))
                let ch = J.dict(m["rank_change_data"])
                out.append(HGRankedActor(rank: r, id: id, name: name, avatar: J.str(base["user_avatar"]),
                                         score: J.str(J.dict(m["rec_text_item"])["RecommendText"]), intro: intro,
                                         subTitles: J.arr(m["sub_title_list"]).map { Self.cleanText(J.str(J.dict($0)["content"])) }.filter { !$0.isEmpty },
                                         change: .init(rawValue: J.int(ch["rank_change_type"])) ?? .flat, changeNum: J.int(ch["ChangeNum"]),
                                         gender: ActorGender.infer(name: name, intro: intro)))
            }
        }
        return HGActorRankPage(actors: out, rankDate: date, hasMore: J.bool(data["has_more"]),
                               nextOffset: J.int(data["next_offset"]) > 0 ? J.int(data["next_offset"]) : offset + out.count,
                               sessionId: J.str(data["session_id"]).isEmpty ? sessionId : J.str(data["session_id"]))
    }

    static func cleanText(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Gender filter (upstream ranking has none): curated names + intro keywords, as in hongguo-actor.js.
enum ActorGender {
    static let female: Set<String> = ["王志欣", "王小亿", "何雅馨", "至春禾", "张晋宜", "余茵", "郭宇欣", "董薇", "丁磊", "郇依心",
        "孟娜", "林秋奈", "羽翎", "马乐婕", "马秋元", "谭盐盐", "韩雨彤", "黄宁馨", "高子怡", "梁雯晶",
        "袁祎晴", "黎晟萱", "刘念", "袁子晶", "翟一莹", "贾翼瑄", "钟熙", "斯佳丽", "柴慧琴", "滕泽文",
        "孙芊芊", "许梦圆", "赵夕汐", "徐艺真", "赵佳", "张楚萱", "侯呈玥", "黄云云", "刘美娜", "邓灵枢",
        "孙艺燃", "张嘉妤", "陈淑云", "李偌菡", "琪梵", "索菲", "天儿", "姜熙饶", "何雨桐", "方梨",
        "苏曼", "董洁", "涂蕊", "杨泽琳", "冯艺然", "周洛伊", "裴颤", "李柯以", "林琦婷", "蒋昕妍",
        "赵慧楠", "朱诗妤", "胡冬晴"]
    static let male: Set<String> = ["申浩男", "柯淳", "鹿单东", "白方文", "岳冬峰", "严子贤", "孙樾", "曾辉", "舒童",
        "王凯沐", "梁思伟", "张翅", "李世鑫", "卡戎", "程宇峰", "沉思", "蔡欣洋", "时康", "王皓祯",
        "代高政", "姚冠宇", "刘安歌", "刘润铭", "魏尊", "尤洋", "王培延", "马瑞泽", "陈俊儒", "魏华",
        "赵振栋", "刘萧旭", "皮德胜", "杜培源", "鞠振涛", "郭勐", "诸葛迪迪", "李芮", "杨泠铸", "徐金海",
        "孙明文", "任飞跃", "张子唯", "黄旭高", "曾祥羽", "徐成刚", "徐云龙", "王猛", "刘国际", "钟世岩",
        "张振宇", "徐卫龙", "王永新", "宋敬伟", "孙启鑫", "宋金阳", "孙一平", "董勋辉", "张震", "王嘉皓",
        "郑国锋", "李军", "徐大宁", "张正", "李京雨", "乔狄", "张铭祥", "户元松", "何红华", "冷海铭",
        "楚晓龙", "晟铭", "商泽华", "吴昊", "罗大涛", "刘昱辰", "王嘉禾", "陈宇星", "李腾", "叶新龙",
        "祝贺", "王梓豪", "余嘉政", "李治源", "艺丰", "张辉", "张海峰", "潘俊", "廖峰", "汪奇",
        "杨灿", "易浩铭", "六子", "谭鑫", "范少雄"]
    static func infer(name: String, intro: String) -> HGRankedActor.Gender {
        if female.contains(name) { return .female }
        if male.contains(name) { return .male }
        if intro.range(of: #"女演员|女艺人|女歌手|女模"#, options: .regularExpression) != nil { return .female }
        if intro.range(of: #"男演员|男艺人|男歌手|男模"#, options: .regularExpression) != nil { return .male }
        return .all
    }
}
