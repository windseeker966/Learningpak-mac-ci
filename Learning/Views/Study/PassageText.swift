import SwiftUI
import UIKit

/// 划词菜单里的操作
enum PassageWordAction {
    case translate
    case add
    /// 查看已加入的生词
    case entry
}

/// 阅读文章的一段：衬线字体，可以划选。划选后的菜单里有「AI 翻译」「加入生词本」，
/// 选中已加入的生词时是「查看生词」。结果像系统翻译那样，在选区上方或下方弹出悬浮窗。生词本里的词标黄。
struct PassageParagraphText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    /// 标黄的范围（生词本里的词）
    let highlights: [NSRange]
    /// 另外标色的范围（如 AI 短文复习里考的词），不算生词本里的词
    var marks: [(range: NSRange, color: UIColor)] = []
    /// 插在正文 at 处显示的上标（如 AI 短文复习里词的序号），不算正文：
    /// highlights、marks 和交给 popover 的选区都按不含上标的 text 计
    var superscripts: [(at: Int, text: String)] = []
    /// 某个操作在悬浮窗里显示的内容；range 是选区（查看生词时是那个生词的范围）
    var popover: (PassageWordAction, NSRange) -> AnyView

    /// 超过这么多个词就不算「生词」，菜单里不给加入，AI 翻译按整段翻译
    static let maxWords = 6

    static func isWordLike(_ s: String) -> Bool {
        s.split(whereSeparator: \.isWhitespace).count <= maxWords
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = PassageTextView()
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
        let c = context.coordinator
        c.parent = self
        let key = "\(fontSize)|\(highlights.map { "\($0.location),\($0.length)" }.joined(separator: ";"))|"
            + marks.map { "\($0.range.location),\($0.range.length),\($0.color.hashValue)" }.joined(separator: ";") + "|"
            + superscripts.map { "\($0.at),\($0.text)" }.joined(separator: ";") + "|\(text)"
        guard key != c.renderedKey else { return }
        c.renderedKey = key
        c.measured = [:]
        let selected = tv.selectedRange
        tv.attributedText = attributed()
        if selected.location + selected.length <= tv.attributedText.length { tv.selectedRange = selected }
        tv.invalidateIntrinsicContentSize()
    }

    private func attributed() -> NSAttributedString {
        let base = UIFont.systemFont(ofSize: fontSize)
        let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: fontSize) } ?? base
        let style = NSMutableParagraphStyle()
        style.lineSpacing = fontSize * 0.45
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.label, .paragraphStyle: style,
        ])
        let length = s.length
        for r in highlights where r.location + r.length <= length {
            s.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.45), range: r)
        }
        for m in marks where m.range.location + m.range.length <= length {
            s.addAttribute(.backgroundColor, value: m.color, range: m.range)
            s.addAttribute(.font, value: UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold)
                ?? font.fontDescriptor, size: fontSize), range: m.range)
        }
        // 从后往前插入上标，前面的位置不变
        for sup in inserts.reversed() where sup.at <= length {
            s.insert(NSAttributedString(string: sup.text, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize * 0.55, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel, .baselineOffset: fontSize * 0.42, .paragraphStyle: style,
            ]), at: sup.at)
        }
        return s
    }

    private var inserts: [(at: Int, text: String)] { superscripts.sorted { $0.at < $1.at } }

    /// 正文里的范围 → 显示的文字里的范围（插在范围开头处的上标算在前面，插在结尾处的算在后面）
    func displayRange(_ r: NSRange) -> NSRange {
        let before = { (limit: Int, inclusive: Bool) in
            inserts.filter { inclusive ? $0.at <= limit : $0.at < limit }.reduce(0) { $0 + ($1.text as NSString).length }
        }
        let start = r.location + before(r.location, true)
        let end = r.location + r.length + before(r.location + r.length, false)
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// 显示的文字里的范围 → 正文里的范围；落在上标上的位置归到上标插入处
    func textRange(_ d: NSRange) -> NSRange {
        func plain(_ location: Int) -> Int {
            var shift = 0
            for sup in inserts {
                let at = sup.at + shift, length = (sup.text as NSString).length
                if location <= at { break }
                if location < at + length { return sup.at }
                shift += length
            }
            return location - shift
        }
        let start = plain(d.location), end = plain(d.location + d.length)
        return NSRange(location: start, length: max(end - start, 0))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? (uiView.bounds.width > 0 ? uiView.bounds.width : 600)
        guard width.isFinite, width > 0 else { return nil }
        let key = Int(width.rounded())
        if let h = context.coordinator.measured[key] { return CGSize(width: width, height: h) }
        let h = ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        context.coordinator.measured[key] = h
        return CGSize(width: width, height: h)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PassageParagraphText?
        var renderedKey = ""
        var measured: [Int: CGFloat] = [:]

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let parent, range.length > 0 else { return nil }
            // 换算成不含上标的正文再去掉两端的空白和标点
            let trimmed = Self.trim(parent.textRange(range), in: parent.text as NSString)
            guard trimmed.length > 0 else { return nil }
            let hit = parent.highlights.first { NSIntersectionRange($0, trimmed).length > 0 }
            func item(_ title: String, _ image: String, _ action: PassageWordAction, _ r: NSRange) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: image)) { [weak self, weak textView] _ in
                    guard let self, let textView else { return }
                    self.present(action, range: r, in: textView)
                }
            }
            var actions: [UIMenuElement] = []
            if let hit { actions.append(item("查看生词", "character.book.closed", .entry, hit)) }
            actions.append(item("AI 翻译", "character.bubble", .translate, trimmed))
            if hit == nil, PassageParagraphText.isWordLike((parent.text as NSString).substring(with: trimmed)) {
                actions.append(item("加入生词本", "plus.rectangle.on.rectangle", .add, trimmed))
            }
            return UIMenu(children: actions + suggestedActions)
        }

        /// 在选区旁弹出悬浮窗，箭头指向选中的文字。range 按正文计
        private func present(_ action: PassageWordAction, range: NSRange, in textView: UITextView) {
            guard let parent else { return }
            let shown = parent.displayRange(range)
            let anchor = Self.rect(of: shown, in: textView)
            textView.selectedRange = NSRange(location: shown.location, length: 0)
            WordPopoverPresenter.present(parent.popover(action, range), from: textView, rect: anchor)
        }

        /// 选区在文本框里的位置；跨行时取各行的并集
        private static func rect(of range: NSRange, in textView: UITextView) -> CGRect {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return textView.bounds }
            let rects = textView.selectionRects(for: textRange).map(\.rect).filter { !$0.isEmpty }
            return rects.dropFirst().reduce(rects.first ?? textView.bounds) { $0.union($1) }
        }

        /// 去掉选区两端的空白和标点（双击选词时常带上逗号、引号）
        static func trim(_ range: NSRange, in text: NSString) -> NSRange {
            let skip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            var start = range.location, end = range.location + range.length
            func isSkip(_ i: Int) -> Bool {
                guard let scalar = UnicodeScalar(text.character(at: i)) else { return false }
                return skip.contains(scalar)
            }
            while start < end, isSkip(start) { start += 1 }
            while end > start, isSkip(end - 1) { end -= 1 }
            return NSRange(location: start, length: end - start)
        }
    }
}

/// 不参与焦点系统的文本框；手指和 Pencil 都能划选
private final class PassageTextView: UITextView {
    override var canBecomeFocused: Bool { false }
}
