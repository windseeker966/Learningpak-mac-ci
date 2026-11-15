import SwiftMath
import SwiftUI
import UIKit

// LaTeX 公式渲染：用 SwiftMath（iosMath 的 Swift 移植，原生 CoreText 排版，MIT）把公式排成图片，
// 再作为行内图片嵌进正文（SwiftUI Text 或 UITextView 的 NSTextAttachment），按基线对齐。
// 支持 $…$、\(…\) 行内公式，$$…$$、\[…\] 独立公式。
// 图片按当前像素密度（屏幕倍率 × 页面缩放）渲染并缓存：高倍率图片缩小显示时
// CoreAnimation 只做简单的双线性采样，笔画会发虚，所以不预先渲染一张最大倍率的图。

extension NSAttributedString.Key {
    /// 公式附件上记下原始 LaTeX，划选提问时还原成 $…$ 交给 AI
    static let mathSource = NSAttributedString.Key("LearningMathSource")
}

/// 带公式的 Markdown 行内文字：公式先换成私用区占位符，整段解析 Markdown 后再换回，
/// 这样加粗、斜体、链接可以跨过公式（如 **选择（$|$）**）
nonisolated enum MathInline {
    private static let base: UInt32 = 0xE000
    private static let limit = 6400  // 私用区 U+E000–U+F8FF

    struct Parsed {
        let text: AttributedString
        let maths: [(latex: String, display: Bool)]
    }

    static func parse(_ s: String) -> Parsed {
        var plain = ""
        var maths: [(latex: String, display: Bool)] = []
        for seg in MathSplitter.split(s) {
            switch seg {
            case .text(let t):
                plain += t
            case .math(let latex, let display):
                if maths.count < limit, let scalar = Unicode.Scalar(base + UInt32(maths.count)) {
                    plain.unicodeScalars.append(scalar)
                    maths.append((latex, display))
                } else {
                    plain += display ? "$$\(latex)$$" : "$\(latex)$"
                }
            }
        }
        let text = (try? AttributedString(markdown: plain, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(plain)
        return Parsed(text: text, maths: maths)
    }

    /// 把一段解析后的文字按占位符切回普通文字与公式
    static func pieces(_ s: String, _ maths: [(latex: String, display: Bool)]) -> [MathSegment] {
        var out: [MathSegment] = []
        var buf = ""
        for scalar in s.unicodeScalars {
            let i = Int(scalar.value) - Int(base)
            if i >= 0, i < maths.count {
                if !buf.isEmpty { out.append(.text(buf)); buf = "" }
                out.append(.math(maths[i].latex, display: maths[i].display))
            } else {
                buf.unicodeScalars.append(scalar)
            }
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }
}

/// 一个排好的公式
struct RenderedMath {
    let image: UIImage
    /// 基线到图片底边的距离（pt）
    let descent: CGFloat
}

enum MathRenderer {
    private final class Box {
        let value: RenderedMath?
        init(_ v: RenderedMath?) { value = v }
    }

    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 500
        return c
    }()

    /// 第一次排版前补上 SwiftMath 缺的符号（只执行一次）
    private static let symbolsRegistered: Void = LatexCompat.registerSymbols()

    /// 排版失败（语法错误、不支持的命令）时返回 nil，调用方按原文显示
    /// scale 为显示处的像素密度，即环境的 renderScale（屏幕像素密度 × 页面缩放倍率）
    static func render(_ latex: String, fontSize: CGFloat, color: UIColor, display: Bool,
                       scale: CGFloat) -> RenderedMath? {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let scale = max(1, (scale * 100).rounded() / 100)
        let key = "\(display)|\(fontSize)|\(resolved.hash)|\(scale)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        _ = symbolsRegistered
        let value = make(latex, fontSize: fontSize, color: resolved, display: display, scale: scale)
        cache.setObject(Box(value), forKey: key)
        return value
    }

    private static func make(_ latex: String, fontSize: CGFloat, color: UIColor, display: Bool,
                             scale: CGFloat) -> RenderedMath? {
        let label = MTMathUILabel()
        label.displayErrorInline = false
        // XITS（Times 风格）的笔画粗细与正文苹方接近；Latin Modern 太细，和中文放在一起显得淡
        let font = MathFont.xitsFont.mtfont(size: fontSize)
        // 公式里的中文（\text{利用率}）用系统中文字体
        font.fallbackFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil)
        label.font = font
        label.labelMode = display ? .display : .text
        label.textAlignment = .left
        label.textColor = color
        // 图片按公式的自然尺寸生成。UILabel 按最终窄图片框重新排版时可能
        // 把公式拆成多行，而图片高度仍是单行的测量值，导致符号被裁掉。
        // 公式整体的换行／缩放交给外层正文，图片内部不按框宽换行。
        label.preferredMaxLayoutWidth = 100_000
        // 先把 SwiftMath 不认识的常见命令（\dots、\overset 等）改写成等价写法
        label.latex = LatexCompat.rewrite(latex)
        guard label.error == nil else { return nil }
        let size = label.intrinsicContentSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        // MTMathUILabel 把排版结果在框内纵向居中，内容高不足半个字号时（如单个 ε、x）按半个字号居中。
        // 若框高取内容高，公式会被推到图片底边以下，下半截被裁掉。框高取它居中用的高度，
        // 基线就正好落在距框底 descent 处；图片另按内容高生成。
        label.frame = CGRect(origin: .zero, size: CGSize(width: ceil(size.width),
                                                         height: max(size.height, label.fontSize / 2)))
        label.layoutIfNeeded()
        guard let list = label.displayList else { return nil }
        // 基线距底边对齐到半个点：落在半个像素上整张图会被插值成模糊的；
        // 不按 scale 取整，各缩放倍率下的排版才完全一致，缩放后重绘不会挪动文字。
        let descent = (max(0, list.descent) * 2).rounded(.up) / 2
        let bounds = CGRect(origin: .zero,
                            size: CGSize(width: ceil(size.width), height: ceil(max(0, list.ascent) + descent)))
        guard bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        // 与 SwiftMath 自带的 MathImage 相同：翻转成数学坐标系后直接画排版结果
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.saveGState()
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            cg.translateBy(x: 0, y: descent - list.descent)
            list.draw(cg)
            cg.restoreGState()
        }
        return RenderedMath(image: image, descent: descent)
    }

    /// 排版失败时显示的原文
    static func fallbackText(_ latex: String, display: Bool) -> String {
        display ? "$$\(latex)$$" : "$\(latex)$"
    }
}

// MARK: - SwiftUI

enum MathText {
    /// 带公式的行内文字：普通部分按 Markdown 行内语法，公式部分为基线对齐的图片
    /// scale 传环境的 renderScale，公式图片按此像素密度渲染
    static func text(_ s: String, font: UIFont, scale: CGFloat) -> Text {
        let parsed = MathInline.parse(s)
        var result = Text("")
        for run in parsed.text.runs {
            for seg in MathInline.pieces(String(parsed.text[run.range].characters), parsed.maths) {
                let piece: Text
                switch seg {
                case .text(let t):
                    piece = Text(AttributedString(t, attributes: run.attributes))
                case .math(let latex, let display):
                    if let m = MathRenderer.render(latex, fontSize: font.pointSize * 1.05, color: .label,
                                                     display: display, scale: scale) {
                        piece = Text(Image(uiImage: m.image)).baselineOffset(-m.descent)
                    } else {
                        piece = Text(MathRenderer.fallbackText(latex, display: display)).foregroundStyle(.secondary)
                    }
                }
                result = Text("\(result)\(piece)")
            }
        }
        return result
    }
}

/// 独立一段的公式（$$…$$ 单独成段）：居中，过宽时缩小
struct MathBlockView: View {
    let latex: String
    @Environment(\.renderScale) private var renderScale

    var body: some View {
        let size = UIFont.preferredFont(forTextStyle: .body).pointSize * 1.15
        if let m = MathRenderer.render(latex, fontSize: size, color: .label, display: true, scale: renderScale) {
            Image(uiImage: m.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: m.image.size.width)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityLabel(latex)
        } else {
            Text(MathRenderer.fallbackText(latex, display: true))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

/// 可划选提问的独立公式：放在 UITextView 里居中显示，划选时还原为 $$…$$；过宽时按比例缩小
struct SelectableMathBlock: View {
    let latex: String
    var source: String
    var onSelect: (SelectionAction) -> Void
    @Environment(\.renderScale) private var renderScale
    @State private var width: CGFloat = 0

    var body: some View {
        Group {
            if width > 0 {
                SelectableText(attributed: RichText.displayMath(latex, maxWidth: width, scale: renderScale),
                               source: source, onAction: onSelect)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.vertical, 4)
    }
}

// MARK: - UITextView

extension RichText {
    /// 公式附件：基线对齐，附件字符上记下原始 LaTeX
    static func mathAttachment(_ latex: String, display: Bool, font: UIFont, color: UIColor,
                               scale: CGFloat) -> NSAttributedString {
        guard let m = MathRenderer.render(latex, fontSize: font.pointSize * 1.05, color: color, display: display,
                                          scale: scale) else {
            return NSAttributedString(string: MathRenderer.fallbackText(latex, display: display),
                                      attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        }
        let attachment = NSTextAttachment()
        attachment.image = m.image
        attachment.bounds = CGRect(x: 0, y: -m.descent, width: m.image.size.width, height: m.image.size.height)
        let s = NSMutableAttributedString(attachment: attachment)
        s.addAttributes([.font: font, .mathSource: MathRenderer.fallbackText(latex, display: display)],
                        range: NSRange(location: 0, length: s.length))
        return s
    }

    /// 单独一段的公式：居中，宽于 maxWidth 时缩小
    static func displayMath(_ latex: String, maxWidth: CGFloat, scale: CGFloat) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .body)
        let size = font.pointSize * 1.15
        let out = NSMutableAttributedString()
        if let m = MathRenderer.render(latex, fontSize: size, color: .label, display: true, scale: scale) {
            let ratio = min(1, maxWidth / max(m.image.size.width, 1))
            let attachment = NSTextAttachment()
            attachment.image = m.image
            attachment.bounds = CGRect(x: 0, y: -m.descent * ratio,
                                       width: m.image.size.width * ratio, height: m.image.size.height * ratio)
            out.append(NSAttributedString(attachment: attachment))
            out.addAttributes([.font: font, .mathSource: MathRenderer.fallbackText(latex, display: true)],
                              range: NSRange(location: 0, length: out.length))
        } else {
            out.append(NSAttributedString(string: MathRenderer.fallbackText(latex, display: true),
                                          attributes: [.font: UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9,
                                                                                          weight: .regular),
                                                       .foregroundColor: UIColor.secondaryLabel]))
        }
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// 取一段富文本的文字，公式附件还原成 $…$
    static func plainText(_ s: NSAttributedString) -> String {
        var out = ""
        s.enumerateAttribute(.mathSource, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            if let src = value as? String {
                out += src
            } else {
                out += (s.string as NSString).substring(with: range)
            }
        }
        return out
    }
}
