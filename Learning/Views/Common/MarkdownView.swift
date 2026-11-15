import SwiftUI

/// 轻量 Markdown 渲染：标题、段落、列表、引用、分隔线、表格、代码块、LaTeX 公式。
/// 行内语法（加粗、斜体、行内代码、链接）交给 AttributedString；公式见 MathRendering.swift。
struct MarkdownView: View {
    let text: String
    /// 这段内容的出处（如「你刚才的讲解」），划选提问时一并告诉 AI
    var source: String = ""
    /// 传入后，正文可划选并「就此提问 / 解释这段」
    var onSelect: ((SelectionAction) -> Void)? = nil
    /// 传入后，单独一行的 [[图 id]] 显示为原书图片
    var pack: StudyPack? = nil
    /// 正在流式生成：每次刷新文字都不同，不进解析缓存（免得挤掉讲解的缓存），也先不开文字选择
    var streaming = false
    @Environment(\.renderScale) private var renderScale

    var body: some View {
        let blocks = streaming ? MarkdownParser.parse(text) : MarkdownParser.cachedParse(text)
        VStack(alignment: .leading, spacing: 10) {
            if onSelect != nil {
                // 可划选时：连续的文字块合进一个文本框，表格、图片等单独放。
                // 每个文本框都要单独排版，逐块一个会让长讲解切换时明显卡顿
                ForEach(Array(Self.segments(blocks).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let group):
                        SelectableText(attributed: RichText.document(group, scale: renderScale), source: source, onAction: onSelect)
                    case .other(let block):
                        blockView(block)
                    }
                }
            } else if streaming {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            } else {
                // 可划选模式由 UITextView 负责选中；SwiftUI 的文字选择会遍历整页，只在这里开启
                Group {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Segment {
        case text([MarkdownBlock])
        case other(MarkdownBlock)
    }

    private static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var out: [Segment] = []
        var group: [MarkdownBlock] = []
        for b in blocks {
            if b.isTextual {
                group.append(b)
            } else {
                if !group.isEmpty { out.append(.text(group)); group = [] }
                out.append(.other(b))
            }
        }
        if !group.isEmpty { out.append(.text(group)) }
        return out
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            let style: UIFont.TextStyle = level <= 1 ? .title2 : level == 2 ? .title3 : .headline
            textBlock(s, style: style, bold: true)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let s):
            textBlock(s)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        textBlock(item.text)
                    }
                    .padding(.leading, CGFloat(item.level) * 20)
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.tint.opacity(0.5)).frame(width: 4)
                textBlock(s, color: .secondaryLabel)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        case .code(let s):
            Text(s)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        case .figure(let id):
            if let pack, let f = pack.figures[id] {
                FigureView(pack: pack, figure: f).padding(.vertical, 4)
            }
        case .math(let latex):
            if let onSelect {
                SelectableMathBlock(latex: latex, source: source, onSelect: onSelect)
            } else {
                MathBlockView(latex: latex)
            }
        }
    }

    /// 可划选提问时单元格也用 UITextView，否则用 SwiftUI Text
    private func tableView(header: [String], rows: [[String]]) -> some View {
        MarkdownTable(header: header, rows: rows) { text, isHeader in
            if let onSelect {
                SelectableText(attributed: RichText.markdown(text, bold: isHeader, scale: renderScale),
                               source: source.isEmpty ? "表格" : "\(source)中的表格", onAction: onSelect)
            } else {
                MathText.text(text, font: .preferredFont(forTextStyle: .body), scale: renderScale)
                    .bold(isHeader)
            }
        }
    }

    /// 可划选提问时用 UITextView，否则用 SwiftUI Text
    @ViewBuilder
    private func textBlock(_ s: String, style: UIFont.TextStyle = .body, bold: Bool = false,
                           color: UIColor = .label) -> some View {
        if let onSelect {
            SelectableText(attributed: RichText.markdown(s, style: style, bold: bold, color: color, scale: renderScale),
                           source: source, onAction: onSelect)
        } else {
            MathText.text(s, font: .preferredFont(forTextStyle: style), scale: renderScale)
                .font(Font(UIFont.preferredFont(forTextStyle: style)))
                .bold(bold)
                .foregroundStyle(Color(color))
        }
    }
}

/// Markdown 表格：铺满可用宽度，按各列内容长短分配列宽，单元格内自动换行
struct MarkdownTable<Cell: View>: View {
    let header: [String]
    let rows: [[String]]
    /// 单元格内容（文字可含行内公式）；第二个参数表示是否表头
    @ViewBuilder let cell: (String, Bool) -> Cell
    @State private var width: CGFloat = 0

    private var columns: Int { header.count }

    /// 列宽权重：按该列最长内容的「显示宽度」估算（汉字算 1，ASCII 算 0.55），限制在 3～18 之间
    private var weights: [CGFloat] {
        (0..<columns).map { i in
            let cells = [header[i]] + rows.map { i < $0.count ? $0[i] : "" }
            let longest = cells.map { cell in
                cell.reduce(0.0) { $0 + ($1.isASCII ? 0.55 : 1.0) }
            }.max() ?? 1
            return CGFloat(min(max(longest, 3), 18))
        }
    }

    var body: some View {
        let w = weights, total = w.reduce(0, +)
        VStack(spacing: 0) {
            if width > 0 {
                row(header, widths: w.map { width * $0 / total }, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Divider()
                    row(r, widths: w.map { width * $0 / total }, isHeader: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columns, id: \.self) { i in
                cell(i < cells.count ? cells[i] : "", isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(width: widths[i], alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)  // 撑满整行高度，竖线才不会断
                    .overlay(alignment: .trailing) {
                        if i < columns - 1 { Rectangle().fill(.quaternary).frame(width: 0.5) }
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(isHeader ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
    }
}

extension MarkdownBlock {
    /// 标题、段落、列表、引用可以合进同一个文本框
    var isTextual: Bool {
        switch self {
        case .heading, .paragraph, .list, .quote: true
        default: false
        }
    }

    /// 用作缓存键的文字内容
    var textKey: String {
        switch self {
        case .heading(let l, let s): "h\(l):" + s
        case .paragraph(let s): "p:" + s
        case .list(let items): "l:" + items.map { "\($0.level)\($0.marker)\($0.text)" }.joined(separator: "\u{2}")
        case .quote(let s): "q:" + s
        case .rule: "r"
        case .code(let s): "c:" + s
        case .table(let h, let r): "t:" + h.joined() + r.map { $0.joined() }.joined()
        case .figure(let id): "f:" + id
        case .math(let s): "m:" + s
        }
    }
}

enum MarkdownBlock {
    struct ListItem {
        let level: Int
        let marker: String
        let text: String
    }

    case heading(Int, String)
    case paragraph(String)
    case list([ListItem])
    case quote(String)
    case rule
    case code(String)
    case table([String], [[String]])
    /// 单独一行的 [[图 id]]
    case figure(String)
    /// 独立成段的公式（$$…$$ 或 \[…\]）
    case math(String)
}

enum MarkdownParser {
    private final class Box { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }
    private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 100
        return c
    }()

    /// 同一段文字只解析一次（界面每次刷新都会重新求值 body）
    static func cachedParse(_ text: String) -> [MarkdownBlock] {
        if let hit = cache.object(forKey: text as NSString) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(Box(blocks), forKey: text as NSString)
        return blocks
    }

    /// 识别 [[图 1.2-fig1.2]] / [[图:1.2-fig1.2]] 这样的占位行
    static func figureID(_ line: String) -> String? {
        guard line.hasPrefix("[[图"), line.hasSuffix("]]") else { return nil }
        let id = line.dropFirst(3).dropLast(2)
            .trimmingCharacters(in: CharacterSet(charactersIn: " :：\t"))
        return id.isEmpty ? nil : id
    }

    /// 文中引用到的图 id
    static func figureIDs(in text: String) -> Set<String> {
        Set(text.components(separatedBy: "\n").compactMap { figureID($0.trimmingCharacters(in: .whitespaces)) })
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [MarkdownBlock.ListItem] = []
        var quote: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushList() {
            if !listItems.isEmpty { blocks.append(.list(listItems)); listItems = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 代码块
            if line.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }

            // 独立成段的公式：$$ 或 \[ 开头，直到对应的结束符（可跨行）
            if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                let close = line.hasPrefix("$$") ? "$$" : "\\]"
                var collected = [line]
                var j = i
                let firstClosed = line.count > 2 && String(line.dropFirst(2)).contains(close)
                if !firstClosed {
                    while j + 1 < lines.count {
                        j += 1
                        let l = lines[j].trimmingCharacters(in: .whitespaces)
                        collected.append(l)
                        if l.contains(close) { break }
                    }
                }
                let joined = collected.joined(separator: "\n")
                let segs = MathSplitter.split(joined)
                if segs.count == 1, case .math(let latex, true) = segs[0] {
                    flushAll()
                    blocks.append(.math(latex))
                    i = j + 1
                    continue
                }
            }

            if let id = figureID(line) {
                flushAll()
                blocks.append(.figure(id))
                i += 1
                continue
            }

            if line.isEmpty {
                flushAll(); i += 1; continue
            }

            // 表格：本行以 | 开头，下一行是分隔行
            if line.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushAll()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                blocks.append(.table(header, rows))
                continue
            }

            if let (level, content) = heading(line) {
                flushAll(); blocks.append(.heading(level, content)); i += 1; continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushAll(); blocks.append(.rule); i += 1; continue
            }

            if line.hasPrefix(">") {
                flushParagraph(); flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1; continue
            }

            if let item = listItem(raw) {
                flushParagraph(); flushQuote()
                listItems.append(item); i += 1; continue
            }

            // 列表项的续行
            if !listItems.isEmpty, raw.hasPrefix("  ") {
                let last = listItems.removeLast()
                listItems.append(.init(level: last.level, marker: last.marker, text: last.text + "\n" + line))
                i += 1; continue
            }

            flushList(); flushQuote()
            paragraph.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func listItem(_ raw: String) -> MarkdownBlock.ListItem? {
        let indent = raw.prefix { $0 == " " }.count
        let line = raw.dropFirst(indent)
        let level = indent / 2
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return .init(level: level, marker: "•", text: String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .init(level: level, marker: "\(digits).", text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    /// 按 | 分列。公式（$…$、$$…$$、\(…\)）里的 | 不是分隔符；公式外的 \| 是单元格里的竖线
    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        let c = Array(t)
        var out: [String] = []
        var cur = ""
        var dollars = false, paren = false
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count {
                let next = c[i + 1]
                if next == "|" && !dollars && !paren {
                    cur.append("|")
                } else {
                    if next == "(" && !dollars { paren = true }
                    if next == ")" && paren { paren = false }
                    cur.append(ch); cur.append(next)
                }
                i += 2
                continue
            }
            if ch == "$" && !paren {
                dollars.toggle()
                cur.append(ch)
                // $$ 作为一个定界符
                if i + 1 < c.count, c[i + 1] == "$" { cur.append("$"); i += 1 }
            } else if ch == "|" && !dollars && !paren {
                out.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
            i += 1
        }
        out.append(cur)
        // 公式没有闭合（如单独的 $ 金额符号）时退回按 | 直接分列
        if dollars || paren { out = t.components(separatedBy: "|") }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
