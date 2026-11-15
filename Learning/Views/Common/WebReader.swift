import SwiftData
import SwiftUI
import UIKit
import WebKit

/// 内置浏览器（「浏览器」标签页）：在网页里也能划词 AI 翻译、加入生词本
/// （和阅读文章一样，见 WordPopover）。记住上次打开的网页，下次打开接着看。
/// 只能打开英文阅读和查资料的网站，论坛、视频网站打不开（规则见 WebAccess）
struct WebReaderView: View {
    static let lastURLKey = "webReader.lastURL"
    /// 设置里自己加的查资料网站，一行一个域名
    static let extraDomainsKey = "webReader.extraDomains"

    static var extraDomains: [String] {
        (UserDefaults.standard.string(forKey: extraDomainsKey) ?? "").split(separator: "\n").map(String.init)
    }

    @Environment(\.modelContext) private var context
    @State private var page = WebPage()
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            WebPageView(page: page)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        if page.isLoading {
                            ProgressView(value: page.progress).progressViewStyle(.linear)
                        }
                        if let notice = page.notice { noticeBar(notice) }
                    }
                }
                .overlay {
                    if page.url == nil && !page.isLoading {
                        ContentUnavailableView("输入网址或搜索词", systemImage: "safari",
                                               description: Text("在网页里划选英文，菜单里选「AI 翻译」或「加入生词本」。"))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .onAppear {
            page.container = context.container
            // 标签页切回来时也会调用：已经打开了网页就不再重新加载
            guard page.url == nil, !page.isLoading else { return }
            #if DEBUG
            if let debug = UserDefaults.standard.string(forKey: "debugWebURL") {
                page.debugLookup = UserDefaults.standard.string(forKey: "debugWebLookup")
                page.open(debug)
                return
            }
            #endif
            if let last = UserDefaults.standard.string(forKey: Self.lastURLKey) { page.open(last) }
        }
        .onChange(of: page.url) { _, url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
    }

    private func noticeBar(_ notice: WebPage.Notice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(notice.message).font(.callout)
            Spacer(minLength: 0)
            if let url = notice.external {
                Button(notice.externalLabel) {
                    UIApplication.shared.open(url)
                    page.notice = nil
                }
                .buttonStyle(.borderedProminent)
            }
            if let url = notice.retry {
                Button("重试") { page.webView.load(URLRequest(url: url)) }
                    .buttonStyle(.bordered)
            }
            Button("关闭提示", systemImage: "xmark") { page.notice = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(12)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("后退", systemImage: "chevron.backward") { page.webView.goBack() }
                .disabled(!page.canGoBack)
            Button("前进", systemImage: "chevron.forward") { page.webView.goForward() }
                .disabled(!page.canGoForward)
        }
        ToolbarItem(placement: .principal) {
            TextField("网址或搜索", text: $address)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .frame(minWidth: 320, maxWidth: 560)
                .onSubmit {
                    page.open(address)
                    addressFocused = false
                }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if page.isLoading {
                Button("停止", systemImage: "xmark.circle") { page.webView.stopLoading() }
            } else {
                Button("刷新", systemImage: "arrow.clockwise") { page.webView.reload() }
                    .disabled(page.url == nil)
            }
        }
    }
}

/// 一个网页：WKWebView 和它的导航状态；打开过的网页记下来，下次打开浏览器时接着看
@MainActor
@Observable
final class WebPage: NSObject, WKNavigationDelegate {
    let webView = ReaderWebView(frame: .zero, configuration: WebPage.configuration())
    private(set) var url: URL?
    private(set) var title: String?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    /// 页面上方的提示：加载失败，或网页要求在 Safari / 别的 App 里打开
    var notice: Notice?

    struct Notice: Equatable {
        var message: String
        var retry: URL? = nil
        var external: URL? = nil
        var externalLabel = ""
    }
    /// 悬浮窗是新的 SwiftUI 根，要把数据库带过去
    @ObservationIgnored var container: ModelContainer?
    /// 调试：网页加载完后选中这个词，弹出 AI 翻译（-debugWebLookup）
    @ObservationIgnored var debugLookup: String?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.onLookup = { [weak self] action in self?.lookup(action) }
        // apply 标成 @MainActor（因而是 Sendable），才能放进 KVO 的 @Sendable 回调；Xcode 26.6 起不标会报数据竞争
        func observe<V>(_ path: KeyPath<ReaderWebView, V>, _ apply: @escaping @MainActor (WebPage, ReaderWebView) -> Void) {
            observations.append(webView.observe(path) { [weak self] web, _ in
                MainActor.assumeIsolated { if let self { apply(self, web) } }
            })
        }
        observe(\.url) { $0.url = $1.url }
        observe(\.title) { $0.title = $1.title }
        observe(\.canGoBack) { $0.canGoBack = $1.canGoBack }
        observe(\.canGoForward) { $0.canGoForward = $1.canGoForward }
        observe(\.isLoading) { $0.isLoading = $1.isLoading }
        observe(\.estimatedProgress) { $0.progress = $1.estimatedProgress }
    }

    /// 请求手机版网页：iPad 默认按电脑版请求，Google 等网站的电脑版在 iPad 上左右留白多，正文挤在一侧。
    /// User-Agent 末尾加上 Safari 的标识：没有它，有些网站会把这里当成 App 内嵌的网页，不给打开或跳去 Safari
    private static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        // 有的网站（如 x.com）在 viewport 里禁止缩放；和 Safari 一样不理会，总能双指缩放
        config.ignoresViewportScaleLimits = true
        return config
    }

    /// 打开网址；不像网址的（有空格、没有点）用 Google 搜索
    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.contains("://") {
            url = URL(string: text)
        } else if !text.contains(" "), text.contains(".") {
            url = URL(string: "https://" + text)
        } else {
            var c = URLComponents(string: "https://www.google.com/search")
            c?.queryItems = [URLQueryItem(name: "q", value: text)]
            url = c?.url
        }
        if let url { webView.load(URLRequest(url: url)) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if let url = webView.url?.absoluteString { UserDefaults.standard.set(url, forKey: WebReaderView.lastURLKey) }
            ActivityLog.write("web_page", ["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""])
            #if DEBUG
            if let word = debugLookup {
                debugLookup = nil
                let js = """
                (function(w) {
                  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                  let n;
                  while ((n = walker.nextNode())) {
                    const i = n.data.indexOf(w);
                    // 跳过脚本、样式和不可见的元素
                    if (i < 0 || !n.parentElement || n.parentElement.getClientRects().length === 0) continue;
                    const r = document.createRange();
                    r.setStart(n, i); r.setEnd(n, i + w.length);
                    const sel = window.getSelection();
                    sel.removeAllRanges(); sel.addRange(r);
                    return true;
                  }
                  return false;
                })(\(Self.jsString(word)))
                """
                let zoom = UserDefaults.standard.double(forKey: "debugWebZoom")
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    _ = try? await webView.evaluateJavaScript(js)
                    // -debugWebZoom 2：先放大，把选中的词滚到页面中间偏左上，检查缩放后悬浮窗的位置
                    if zoom > 0, let raw = try? await webView.evaluateJavaScript(Self.selectionScript) as? [String: Any],
                       let info = SelectionInfo(raw) {
                        let scroll = webView.scrollView
                        scroll.setZoomScale(zoom * scroll.zoomScale, animated: false)
                        let z = scroll.zoomScale
                        scroll.setContentOffset(CGPoint(x: max(info.rect.minX * z - 200, 0),
                                                        y: info.rect.minY * z - 400), animated: false)
                        try? await Task.sleep(for: .seconds(1))
                    }
                    lookup(PassageParagraphText.isWordLike(word) ? .add : .translate)
                }
            }
            #endif
        }
    }

    /// 不能打开的网站（WebAccess）：拦下主页面的跳转，提示原因。嵌在页面里的小框（登录、视频、广告）不管。
    /// 网页要求在 Safari 或别的 App 里打开（如 x.com 跳到 x-safari-https://）：WKWebView 打不开这种地址，
    /// 取消跳转，提示用户
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if Self.webSchemes.contains(scheme) {
            let blocked = navigationAction.targetFrame?.isMainFrame != false && blockIfNeeded(url)
            decisionHandler(blocked ? .cancel : .allow)
            return
        }
        decisionHandler(.cancel)
        // 只处理主页面的跳转；嵌在页面里的小框（广告等）要求跳出的，不提示
        guard navigationAction.targetFrame?.isMainFrame != false else { return }
        if scheme.hasPrefix("x-safari-"), let https = URL(string: String(url.absoluteString.dropFirst("x-safari-".count))) {
            notice = Notice(message: "这个网站不允许在 App 内的浏览器里打开。", external: https, externalLabel: "在 Safari 中打开")
        } else {
            notice = Notice(message: "这个链接要用别的 App 打开。", external: url, externalLabel: "打开")
        }
        ActivityLog.write("web_external", ["url": url.absoluteString, "from": webView.url?.absoluteString ?? ""])
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { notice = nil }
    }

    /// 服务器重定向到不能打开的网站（如搜索结果、短链接跳过去）：停下
    nonisolated func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            if let url = webView.url, blockIfNeeded(url) { webView.stopLoading() }
        }
    }

    /// 网站不能打开时提示原因、写操作日志，返回 true
    private func blockIfNeeded(_ url: URL) -> Bool {
        let extra = WebReaderView.extraDomains
        guard !WebAccess.allows(url, extra: extra) else { return false }
        let kind = WebAccess.kind(of: url, extra: extra)
        let host = url.host() ?? url.absoluteString
        notice = Notice(message: kind == .blocked
                        ? "\(host) 在 iPad 上打不开：论坛和视频网站只在手机上看。"
                        : "\(host) 不在查资料的网站名单里，需要的话在「设置 › 内置浏览器」里加上。")
        ActivityLog.write("web_blocked", ["url": url.absoluteString, "kind": kind.rawValue,
                                          "from": webView.url?.absoluteString ?? ""])
        return true
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { failed(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { failed(error) }
    }

    /// 加载失败时提示原因，可以重试。取消（又点了别的链接）和上面拦下的跳转不提示
    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }   // 跳转被取消（frame load interrupted）
        guard notice?.external == nil else { return }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        notice = Notice(message: "打不开这个网页：\(e.localizedDescription)", retry: failing)
        ActivityLog.write("web_error", ["url": failing?.absoluteString ?? "", "error": "\(e.domain) \(e.code)"])
    }

    /// WKWebView 能自己加载的地址
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    /// 划选菜单里选了「AI 翻译」或「加入生词本」：取出选中的文字和它所在的段落，在选区旁弹出划词悬浮窗
    private func lookup(_ action: PassageWordAction) {
        Task {
            guard let raw = try? await webView.evaluateJavaScript(Self.selectionScript) as? [String: Any],
                  let info = SelectionInfo(raw), let pageURL = webView.url?.absoluteString else { return }
            let paragraph = info.block as NSString
            var range = NSRange(location: info.offset, length: info.length)
            // 规整空白后位置可能对不上：在这一段里找选中的文字
            if range.location + range.length > paragraph.length || paragraph.substring(with: range) != info.text {
                range = paragraph.range(of: info.text)
            }
            guard range.location != NSNotFound else { return }
            range = PassageParagraphText.Coordinator.trim(range, in: paragraph)
            guard range.length > 0 else { return }
            let selection = VocabSelection(webURL: pageURL, title: webView.title, paragraphText: info.block, range: range)
            var popover = AnyView(WordPopover(selection: selection, action: action))
            if let container { popover = AnyView(popover.modelContainer(container)) }
            WordPopoverPresenter.present(popover, from: webView, rect: viewRect(ofDocumentRect: info.rect))
            _ = try? await webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
        }
    }

    /// 网页文档里的位置（CSS 像素）换算到网页视图里：按滚动视图的缩放倍数放大，再减去滚动位置
    /// （滚动位置已含导航栏下的内边距）。双指缩放后网页报的 visualViewport 和滚动视图对不上，不用它
    private func viewRect(ofDocumentRect r: CGRect) -> CGRect {
        let scroll = webView.scrollView
        let z = scroll.zoomScale
        return CGRect(x: r.minX * z - scroll.contentOffset.x, y: r.minY * z - scroll.contentOffset.y,
                      width: max(r.width * z, 1), height: max(r.height * z, 1))
    }

    private struct SelectionInfo {
        var text: String
        var block: String
        var offset: Int
        var length: Int
        var rect: CGRect

        init?(_ d: [String: Any]) {
            guard let text = d["text"] as? String, let block = d["block"] as? String,
                  let offset = (d["offset"] as? NSNumber)?.intValue else { return nil }
            func num(_ k: String) -> CGFloat { CGFloat((d[k] as? NSNumber)?.doubleValue ?? 0) }
            self.text = text
            self.block = block
            self.offset = offset
            length = (text as NSString).length
            rect = CGRect(x: num("x"), y: num("y"), width: max(num("w"), 1), height: max(num("h"), 1))
        }
    }

    /// 选中的文字、所在段落（最近的块级元素，空白规整为一个空格）、在段落里的位置，
    /// 以及选区在整个文档里的位置（CSS 像素）
    private static let selectionScript = """
    (function() {
      const sel = window.getSelection();
      if (!sel || sel.rangeCount === 0) return null;
      const text = sel.toString().replace(/\\s+/g, ' ');
      if (!text.trim()) return null;
      const r = sel.getRangeAt(0);
      const blocks = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,td,th,dd,dt,figcaption,pre,div,article,section';
      let el = r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement;
      while (el && el !== document.body && !el.matches(blocks)) el = el.parentElement;
      if (!el) el = document.body;
      const pre = document.createRange();
      pre.selectNodeContents(el);
      pre.setEnd(r.startContainer, r.startOffset);
      const prefix = pre.toString().replace(/\\s+/g, ' ');
      const block = el.textContent.replace(/\\s+/g, ' ');
      const b = r.getBoundingClientRect();
      return { text: text, block: block, offset: prefix.length,
               x: b.left + window.scrollX, y: b.top + window.scrollY, w: b.width, h: b.height };
    })()
    """

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }
}

/// 划选菜单里加上「AI 翻译」「加入生词本」
final class ReaderWebView: WKWebView {
    var onLookup: ((PassageWordAction) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context else { return }
        let items = UIMenu(options: .displayInline, children: [
            UIAction(title: "AI 翻译", image: UIImage(systemName: "character.bubble")) { [weak self] _ in
                self?.onLookup?(.translate)
            },
            UIAction(title: "加入生词本", image: UIImage(systemName: "plus.rectangle.on.rectangle")) { [weak self] _ in
                self?.onLookup?(.add)
            },
        ])
        builder.insertChild(items, atStartOfMenu: .root)
    }
}

private struct WebPageView: UIViewRepresentable {
    let page: WebPage

    func makeUIView(context: Context) -> ReaderWebView { page.webView }
    func updateUIView(_ uiView: ReaderWebView, context: Context) {}
}
