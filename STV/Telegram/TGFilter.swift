import Foundation

/// User blocklist rule. Matches post text, inline-button text and link domains.
struct TGRule: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case keyword, regex, domain
        var label: String { switch self { case .keyword: "关键词"; case .regex: "正则"; case .domain: "链接域名" } }
    }
    var id = UUID()
    var kind: Kind
    var pattern: String
    /// nil = all channels; otherwise a channel username (lowercased).
    var channel: String? = nil
    var enabled = true

    func matches(_ p: TGPost) -> Bool {
        let pat = pattern.trimmingCharacters(in: .whitespaces)
        guard enabled, !pat.isEmpty else { return false }
        if let channel, channel != p.channel.lowercased() { return false }
        let hay = ([p.text] + p.buttons.map(\.text) + [p.preview?.title ?? "", p.preview?.desc ?? ""]).joined(separator: "\n")
        switch kind {
        case .keyword:
            return hay.range(of: pat, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        case .regex:
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return false }
            let all = hay + "\n" + (p.links + p.buttons.map(\.url)).joined(separator: "\n")
            return re.firstMatch(in: all, range: NSRange(location: 0, length: (all as NSString).length)) != nil
        case .domain:
            let d = pat.lowercased().replacingOccurrences(of: "*.", with: "")
            return p.linkDomains.contains { $0 == d || $0.hasSuffix("." + d) }
        }
    }
}

enum TGFilterMode: String, Codable, CaseIterable {
    case hide, fold
    var label: String { self == .hide ? "直接隐藏" : "折叠为「已屏蔽」" }
}

struct TGVerdict: Hashable {
    var blocked: Bool
    var reason: String
    static let pass = TGVerdict(blocked: false, reason: "")
}

/// Rule export / import format (JSON).
struct TGRuleBundle: Codable {
    var version = 1
    var mode: TGFilterMode
    var heuristics: Bool
    var rules: [TGRule]
}

/// Built-in ad heuristics + user rules.
enum TGFilter {
    static let adTags = ["#广告", "#推广", "#赞助", "#ad", "#ads", "#promo", "#sponsored", "【广告】", "[广告]", "（广告）", "(广告)",
                         "广告合作", "商务合作", "投放广告", "广告投放", "sponsored", "advertisement"]
    /// Gambling / casino / payment-scam words that almost never appear in normal channel posts.
    static let spamWords = ["博彩", "娱乐城", "百家乐", "真人荷官", "体育投注", "首充", "彩金", "返水", "棋牌", "赌场", "老虎机", "电子游艺",
                            "usdt", "担保交易", "日赚", "躺赚", "跑分", "代收代付", "网赚", "引流", "接单", "实体店招商", "开户", "存款", "提款秒到",
                            "注册送", "注册即送", "充值", "返利", "佣金"]
    static let callToAction = ["点击", "立即", "下载", "注册", "入口", "官网", "进群", "加群", "联系", "咨询", "福利", "优惠", "领取", "免费领", "扫码",
                               "join", "click", "download", "register", "sign up", "bonus"]

    /// Score-based check; ≥ 3 points = ad.
    static func heuristic(_ p: TGPost) -> TGVerdict {
        if p.isService { return .pass }
        let lower = p.text.lowercased()
        var score = 0, why: [String] = []
        if let t = adTags.first(where: { lower.contains($0.lowercased()) }) { score += 3; why.append("广告标记 \(t)") }
        let spam = spamWords.filter { lower.contains($0) }
        if spam.count >= 2 { score += 3; why.append("推广词 " + spam.prefix(3).joined(separator: "/")) }
        else if spam.count == 1 { score += 1 }
        let cta = callToAction.contains { lower.contains($0) }
        let own = p.channel.lowercased()
        // Bot deep links are how resource channels deliver files, not ads.
        let external = p.buttons.filter { !isOwn($0.url, channel: own) && TGBotLink(url: $0.url) == nil }
        if !external.isEmpty { score += cta || spam.count > 0 ? 3 : 1; why.append("外链按钮 \(external.count) 个") }
        // Pure promo: short text that is mostly links to elsewhere / invite links, no media.
        let invites = (p.links + p.buttons.map(\.url)).filter { $0.contains("t.me/+") || $0.contains("joinchat") || $0.contains("t.me/addlist") }
        let foreign = p.links.filter { !isOwn($0, channel: own) }
        let stripped = HTML.replace("https?://\\S+|t\\.me/\\S+|@[A-Za-z0-9_]{4,}", p.text, "").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.media.isEmpty, !foreign.isEmpty || !invites.isEmpty, stripped.count < 60 {
            score += cta || !invites.isEmpty ? 3 : 2; why.append("纯推广链接")
        }
        if !invites.isEmpty, cta { score += 1 }
        if lower.contains("置顶") || lower.contains("pinned"), !foreign.isEmpty || !external.isEmpty { score += 2; why.append("置顶推广") }
        return score >= 3 ? TGVerdict(blocked: true, reason: why.joined(separator: " · ")) : .pass
    }

    static func isOwn(_ url: String, channel: String) -> Bool {
        guard let c = URLComponents(string: url), let h = c.host?.lowercased() else { return true }
        if h == "t.me" || h == "telegram.me" {
            let first = c.path.split(separator: "/").first.map { $0.lowercased() } ?? ""
            return first == channel || first == "s" || first.isEmpty
        }
        return false
    }

    static func verdict(_ p: TGPost, rules: [TGRule], heuristics: Bool, channelAdBlock: Bool) -> TGVerdict {
        if let r = rules.first(where: { $0.matches(p) }) { return TGVerdict(blocked: true, reason: "规则 \(r.kind.label)：\(r.pattern)") }
        if heuristics && channelAdBlock { return heuristic(p) }
        return .pass
    }

    /// Suggestions for 「长按加入屏蔽」: distinctive words and link domains of a post.
    static func suggestions(_ p: TGPost) -> [TGRule] {
        var out: [TGRule] = []
        for d in Set(p.linkDomains) where d != "t.me" && d != "telegram.me" { out.append(TGRule(kind: .domain, pattern: d)) }
        for b in p.buttons where !b.text.isEmpty { out.append(TGRule(kind: .keyword, pattern: b.text)) }
        let tags = HTML.all("#([\\p{L}\\p{N}_]{2,20})", p.text).map { "#" + $0[1] }
        for t in tags.prefix(4) { out.append(TGRule(kind: .keyword, pattern: t)) }
        if let line = p.text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.count >= 4 }) {
            out.append(TGRule(kind: .keyword, pattern: String(line.prefix(16))))
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.kind.rawValue + $0.pattern.lowercased()).inserted }
    }

    static func export(_ b: TGRuleBundle) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(b)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Accepts the JSON export, or plain lines (`keyword`, `re:pattern`, `domain:example.com`).
    static func importRules(_ text: String) -> TGRuleBundle? {
        if let d = text.data(using: .utf8), let b = try? JSONDecoder().decode(TGRuleBundle.self, from: d) { return b }
        let rules = text.split(whereSeparator: \.isNewline).compactMap { l -> TGRule? in
            let s = l.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("//") else { return nil }
            if s.hasPrefix("re:") { return TGRule(kind: .regex, pattern: String(s.dropFirst(3))) }
            if s.hasPrefix("domain:") { return TGRule(kind: .domain, pattern: String(s.dropFirst(7))) }
            return TGRule(kind: .keyword, pattern: s)
        }
        return rules.isEmpty ? nil : TGRuleBundle(mode: .fold, heuristics: true, rules: rules)
    }
}
