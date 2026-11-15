import Foundation

/// 内置浏览器能打开哪些网站。iPad 上 Chrome、Safari 用系统的屏幕使用时间一直挡着，上网只用内置浏览器：
/// - 英文阅读（x、reddit、英文新闻）：内置浏览器本来就是为它做的，免费；
/// - 查资料（搜索、AI、词典、文档、代码、学校）：在名单里就能打开，名单外的可以在设置里加；
/// - 论坛、中文社交和视频：iPad 上一律不能看（只在手机上看，手机有额度管着），设置里也加不进去。
/// 域名按后缀匹配：`google.com` 包括 `www.google.com`、`aistudio.google.com`。
enum WebAccess {
    enum Kind: String, Equatable {
        case reading, reference, blocked, unlisted

        var allowed: Bool { self == .reading || self == .reference }
    }

    static let reading = [
        "x.com", "twitter.com", "t.co", "reddit.com", "redd.it",
        "apnews.com", "bbc.com", "bbc.co.uk", "reuters.com", "theguardian.com", "nytimes.com", "economist.com",
    ]

    static let reference = [
        // 搜索
        "google.com", "bing.com", "duckduckgo.com",
        // AI
        "chatgpt.com", "claude.ai", "anthropic.com",
        // 词典、百科
        "wikipedia.org", "wiktionary.org", "cambridge.org", "merriam-webster.com", "collinsdictionary.com",
        "oxfordlearnersdictionaries.com", "youdao.com",
        // 代码、文档
        "github.com", "githubusercontent.com", "stackoverflow.com", "stackexchange.com", "developer.apple.com",
        "python.org", "developer.mozilla.org", "cppreference.com", "arxiv.org", "csdn.net", "cnblogs.com",
        // 登录
        "appleid.apple.com",
        // 学校
        "nuist.edu.cn", "chaoxing.com", "yuketang.cn",
    ]

    /// 设置里也加不进去
    static let blocked = [
        "linux.do", "nodeseek.com", "idcflare.com", "v2ex.com", "hostloc.com", "lite.moe", "miaomiao.moe",
        "zhihu.com", "weibo.com", "weibo.cn", "tieba.baidu.com", "douban.com",
        "bilibili.com", "b23.tv", "douyin.com", "kuaishou.com", "iqiyi.com", "youku.com", "v.qq.com",
    ]

    /// `extra` 是设置里自己加的查资料网站
    static func kind(of url: URL, extra: [String] = []) -> Kind {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return .reference }
        if matches(host, blocked) { return .blocked }
        if matches(host, reading) { return .reading }
        if matches(host, reference) || matches(host, extra) { return .reference }
        return .unlisted
    }

    /// 只管网页地址；about:blank、data:、blob: 这类不是网站，放行
    static func allows(_ url: URL, extra: [String] = []) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        return kind(of: url, extra: extra).allowed
    }

    /// 设置里输入的网站整理成域名：去掉协议、路径、端口、开头的 www.，转小写。
    /// 不像域名的、或在挡着的名单里的，返回 nil
    static func domain(fromInput input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = text.range(of: "://") { text = String(text[r.upperBound...]) }
        text = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" })
        if text.hasPrefix("www.") { text.removeFirst(4) }
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."),
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return matches(text, blocked) ? nil : text
    }

    private static func matches(_ host: String, _ domains: [String]) -> Bool {
        domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
