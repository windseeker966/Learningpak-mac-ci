import Foundation

// 内置浏览器能打开哪些网站（WebAccess）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/WebAccess.swift Tests/WebAccessTests.swift -o /tmp/web-access-tests
// /tmp/web-access-tests
@main
private enum WebAccessTests {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; print("FAIL:", what) }
        }
        func kind(_ s: String, extra: [String] = []) -> WebAccess.Kind { WebAccess.kind(of: URL(string: s)!, extra: extra) }

        // 英文阅读
        check(kind("https://x.com/home") == .reading, "x.com")
        check(kind("https://www.reddit.com/r/AskReddit") == .reading, "www.reddit.com")
        check(kind("https://old.reddit.com/") == .reading, "子域名")
        check(kind("https://t.co/abc") == .reading, "x 的短链接")
        // 查资料
        check(kind("https://www.google.com/search?q=fcfs") == .reference, "google 搜索")
        check(kind("https://aistudio.google.com/prompts/new_chat") == .reference, "AI Studio")
        check(kind("https://en.wikipedia.org/wiki/Scheduling") == .reference, "维基")
        check(kind("https://blog.csdn.net/x/article/details/1") == .reference, "CSDN")
        // 论坛、视频：一律挡
        check(kind("https://linux.do/latest") == .blocked, "linux.do")
        check(kind("https://www.nodeseek.com/") == .blocked, "nodeseek")
        check(kind("https://m.bilibili.com/video/1") == .blocked, "B 站手机版")
        check(kind("https://tieba.baidu.com/f?kw=1") == .blocked, "贴吧")
        // 名单外
        check(kind("https://www.fedex.com/") == .unlisted, "名单外")
        check(kind("https://www.fedex.com/", extra: ["fedex.com"]) == .reference, "设置里加了")
        check(kind("https://linux.do/", extra: ["linux.do"]) == .blocked, "挡着的加进 extra 也没用")
        check(kind("https://tieba.baidu.com/", extra: ["baidu.com"]) == .blocked, "加了上级域名，挡着的子域名还是挡")
        // 后缀要按点分开，不能只比字符串结尾
        check(kind("https://notlinux.do/") == .unlisted, "notlinux.do 不是 linux.do")
        check(kind("https://fakegoogle.com/") == .unlisted, "fakegoogle.com 不是 google.com")
        check(kind("https://X.COM/home") == .reading, "大写域名")
        // allows
        check(WebAccess.allows(URL(string: "about:blank")!), "about:blank 放行")
        check(!WebAccess.allows(URL(string: "https://linux.do/")!), "linux.do 不放行")
        check(!WebAccess.allows(URL(string: "http://example.com/")!), "名单外不放行")
        check(WebAccess.allows(URL(string: "https://github.com/x")!), "github 放行")
        // 设置里输入的网站
        check(WebAccess.domain(fromInput: " https://www.FedEx.com/cn/track?id=1 ") == "fedex.com", "去掉协议、www、路径")
        check(WebAccess.domain(fromInput: "docs.rs:443") == "docs.rs", "去掉端口")
        check(WebAccess.domain(fromInput: "linux.do") == nil, "挡着的加不进去")
        check(WebAccess.domain(fromInput: "m.bilibili.com") == nil, "挡着的子域名加不进去")
        check(WebAccess.domain(fromInput: "hello world") == nil, "不像域名")
        check(WebAccess.domain(fromInput: "localhost") == nil, "没有点")

        if failures > 0 { print("\(failures) 项失败"); exit(1) }
        print("WebAccess 全部通过")
    }
}
