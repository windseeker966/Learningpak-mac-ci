import SwiftUI
import UIKit

/// 可划选的文字。选中后，编辑菜单里多出「就此提问」「解释这段」。
/// SwiftUI 的 Text 只支持系统拷贝菜单，所以用 UITextView 实现。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    /// 这段文字的出处，随划选内容一起交给 AI
    var source: String = ""
    var onAction: ((SelectionAction) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = FocuslessTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        (tv as? FocuslessTextView)?.renderingScale = context.environment.renderScale
        let c = context.coordinator
        c.onAction = onAction
        c.source = source
        // 富文本来自缓存，同一内容是同一个对象；只有换了内容才重新设置、重新测量
        if c.current !== attributed {
            if c.current == nil || !attributed.isEqual(to: c.current!) {
                tv.attributedText = attributed
                c.measured = [:]
            }
            c.current = attributed
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? (uiView.bounds.width > 0 ? uiView.bounds.width : 600)
        guard width.isFinite, width > 0 else { return nil }
        let key = Int(width.rounded())
        if let h = context.coordinator.measured[key] { return CGSize(width: width, height: h) }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let h = ceil(size.height)
        context.coordinator.measured[key] = h
        return CGSize(width: width, height: h)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        // 公式是图片附件：不当作可交互的图片（长按「拷贝图像」），长按照常选字
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            if case .textAttachment = textItem.content { return nil }
            return defaultAction
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            if case .textAttachment = textItem.content { return nil }
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        var onAction: ((SelectionAction) -> Void)?
        var source = ""
        /// 当前显示的富文本，以及各宽度下测得的高度（排版很贵，测一次就记住）
        var current: NSAttributedString?
        var measured: [Int: CGFloat] = [:]

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onAction, range.length > 0 else { return nil }
            // 公式是图片附件，取文字时还原成 $…$ 交给 AI
            let attributed = textView.attributedText ?? NSAttributedString()
            let full = textView.text as NSString
            let text = RichText.plainText(attributed.attributedSubstring(from: range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // 取划选位置所在的那一段作为定位上下文（一个文本框里可能有多段）
            let paragraph = RichText.plainText(attributed.attributedSubstring(from: full.paragraphRange(for: range)))
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = SelectionQuote(text: text, source: source, paragraph: paragraph)
            let ask = UIAction(title: "就此提问", image: UIImage(systemName: "questionmark.bubble")) { _ in
                onAction(.ask(quote))
            }
            let explain = UIAction(title: "解释这段", image: UIImage(systemName: "sparkles")) { _ in
                onAction(.explain(quote))
            }
            return UIMenu(children: [ask, explain] + suggestedActions)
        }
    }
}

/// 不参与 iPad 焦点系统的文本框。讲解里文本框很多，焦点系统每次都逐个遍历会明显拖慢切换
final class FocuslessTextView: UITextView {
    override var canBecomeFocused: Bool { false }

    // 选字、长按等只给手指：Apple Pencil 在正文上是写草稿（书写手势挂在外层页面上）
    override func addGestureRecognizer(_ g: UIGestureRecognizer) {
        g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        super.addGestureRecognizer(g)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        for g in gestureRecognizers ?? [] {
            g.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        }
    }

    var renderingScale: CGFloat = 0 {
        didSet {
            if renderingScale != oldValue { setNeedsLayout() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard renderingScale > 0 else { return }
        // TextKit 的文字有独立的子层，单改 UITextView 根层的密度不足以刷新它们。
        updateScale(of: layer)
    }

    private func updateScale(of layer: CALayer) {
        if layer.contentsScale != renderingScale {
            layer.contentsScale = renderingScale
            layer.setNeedsDisplay()
        }
        if layer.shouldRasterize { layer.rasterizationScale = renderingScale }
        for child in layer.sublayers ?? [] { updateScale(of: child) }
    }
}

/// 把 Markdown 行内语法（加粗、斜体、行内代码、链接）或纯文本转成 UITextView 用的富文本
enum RichText {
    /// 转换结果缓存：同样的内容只转换一次，也让 SelectableText 能用对象身份判断内容没变
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 400
        return c
    }()

    private static func cached(_ key: String, _ make: () -> NSAttributedString) -> NSAttributedString {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let value = make()
        cache.setObject(value, forKey: key as NSString)
        return value
    }

    /// scale 为显示处的像素密度（环境的 renderScale），公式图片按它渲染
    static func markdown(_ s: String, style: UIFont.TextStyle = .body, bold: Bool = false,
                         color: UIColor = .label, scale: CGFloat) -> NSAttributedString {
        cached("md|\(style.rawValue)|\(bold)|\(color.hash)|\(scale)|\(s)") {
            makeMarkdown(s, style: style, bold: bold, color: color, scale: scale)
        }
    }

    /// 把连续的标题、段落、列表、引用合成一段富文本，放进同一个文本框
    static func document(_ blocks: [MarkdownBlock], scale: CGFloat) -> NSAttributedString {
        let key = "doc|\(scale)|" + blocks.map(\.textKey).joined(separator: "\u{1}")
        return cached(key) { makeDocument(blocks, scale: scale) }
    }

    private static func makeDocument(_ blocks: [MarkdownBlock], scale: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func para(_ configure: (NSMutableParagraphStyle) -> Void) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.paragraphSpacing = 10
            configure(p)
            return p
        }
        func append(_ piece: NSAttributedString, _ style: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: piece)
            m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
            out.append(m)
        }
        // 段落内部的换行用行分隔符，保持在同一段里
        func oneParagraph(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\u{2028}") }

        for block in blocks {
            switch block {
            case .heading(let level, let s):
                let style: UIFont.TextStyle = level <= 1 ? .title2 : level == 2 ? .title3 : .headline
                append(makeMarkdown(oneParagraph(s), style: style, bold: true, color: .label, scale: scale),
                       para { $0.paragraphSpacingBefore = level <= 2 ? 10 : 4; $0.paragraphSpacing = 6 })
            case .paragraph(let s):
                append(makeMarkdown(oneParagraph(s), style: .body, bold: false, color: .label, scale: scale), para { _ in })
            case .list(let items):
                for (i, item) in items.enumerated() {
                    let indent = CGFloat(item.level) * 20
                    let line = NSMutableAttributedString(
                        string: item.marker + "\t",
                        attributes: [.font: font(.body, bold: false), .foregroundColor: UIColor.secondaryLabel])
                    line.append(makeMarkdown(oneParagraph(item.text), style: .body, bold: false, color: .label, scale: scale))
                    append(line, para {
                        $0.firstLineHeadIndent = indent
                        $0.headIndent = indent + 24
                        $0.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
                        $0.paragraphSpacing = i == items.count - 1 ? 10 : 4
                    })
                }
            case .quote(let s):
                let line = NSMutableAttributedString(
                    string: "▍", attributes: [.font: font(.body, bold: false),
                                              .foregroundColor: UIColor.tintColor.withAlphaComponent(0.5)])
                line.append(makeMarkdown(oneParagraph(s), style: .body, bold: false, color: .secondaryLabel, scale: scale))
                append(line, para { $0.headIndent = 14 })
            default:
                break
            }
        }
        return out
    }

    private static func makeMarkdown(_ s: String, style: UIFont.TextStyle, bold: Bool, color: UIColor,
                                     scale: CGFloat) -> NSAttributedString {
        let base = font(style, bold: bold)
        let out = NSMutableAttributedString()
        // 公式为基线对齐的图片附件，其余按 Markdown 行内语法（加粗等可以跨过公式）
        let parsed = MathInline.parse(s)
        for run in parsed.text.runs {
            var f = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { f = f.adding(.traitBold) }
                if intent.contains(.emphasized) { f = f.adding(.traitItalic) }
                if intent.contains(.code) {
                    f = .monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .regular)
                }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
            if let link = run.link { attrs[.link] = link }
            for seg in MathInline.pieces(String(parsed.text[run.range].characters), parsed.maths) {
                switch seg {
                case .text(let t): out.append(NSAttributedString(string: t, attributes: attrs))
                case .math(let latex, let display):
                    out.append(mathAttachment(latex, display: display, font: base, color: color, scale: scale))
                }
            }
        }
        applyParagraph(out)
        return out
    }

    /// 题面用 unescape: true：题面按纯文本显示，但录入时会照 Markdown 写转义（\*、\$），这里去掉
    static func plain(_ s: String, style: UIFont.TextStyle = .body, color: UIColor = .label,
                      unescape: Bool = false, scale: CGFloat) -> NSAttributedString {
        cached("plain|\(style.rawValue)|\(color.hash)|\(unescape)|\(scale)|\(s)") {
            makePlain(s, style: style, color: color, unescape: unescape, scale: scale)
        }
    }

    private static func makePlain(_ s: String, style: UIFont.TextStyle, color: UIColor, unescape: Bool,
                                  scale: CGFloat) -> NSAttributedString {
        let base = font(style, bold: false)
        let out = NSMutableAttributedString()
        var inCode = false
        for segment in MathSplitter.split(s) {
            switch segment {
            case .text(let text):
                let shown = unescape ? removingEscapes(text, inCode: &inCode) : text
                out.append(NSAttributedString(string: shown, attributes: [.font: base, .foregroundColor: color]))
            case .math(let latex, let display):
                out.append(mathAttachment(latex, display: display, font: base, color: color, scale: scale))
            }
        }
        applyParagraph(out)
        return out
    }

    private static let escapable = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    /// 去掉 Markdown 的反斜杠转义（\* → *）；反引号代码段里的反斜杠是代码本身，原样保留
    /// inCode 跨公式前后的文字段保持
    private static func removingEscapes(_ s: String, inCode: inout Bool) -> String {
        var out = ""
        var pendingEscape = false
        for ch in s {
            if pendingEscape {
                pendingEscape = false
                if !escapable.contains(ch) { out.append("\\") }
                out.append(ch)
            } else if ch == "\\", !inCode {
                pendingEscape = true
            } else {
                if ch == "`" { inCode.toggle() }
                out.append(ch)
            }
        }
        if pendingEscape { out.append("\\") }
        return out
    }

    private static func font(_ style: UIFont.TextStyle, bold: Bool) -> UIFont {
        let f = UIFont.preferredFont(forTextStyle: style)
        return bold ? f.adding(.traitBold) : f
    }

    private static func applyParagraph(_ s: NSMutableAttributedString) {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        s.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: s.length))
    }
}

private extension UIFont {
    func adding(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}
