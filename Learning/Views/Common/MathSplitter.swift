import Foundation

// 把一段文字里的 $…$、$$…$$、\(…\)、\[…\] 切成普通文字与公式（MathRendering 排版用）。
// 只依赖 Foundation：PackFormat/mathcheck 也直接编译这个文件，检查教辅包里的公式和 App 切法一致。

nonisolated enum MathSegment: Equatable {
    case text(String)
    case math(String, display: Bool)
}

/// 把一段文字切成普通文字与公式
nonisolated enum MathSplitter {
    /// 快速判断：没有 $、\(、\[ 就不用切
    static func mayContainMath(_ s: String) -> Bool {
        s.contains("$") || s.contains("\\(") || s.contains("\\[")
    }

    static func split(_ s: String) -> [MathSegment] {
        guard mayContainMath(s) else { return [.text(s)] }
        let c = Array(s)
        var out: [MathSegment] = []
        var buf = ""
        var i = 0

        func flush() {
            if !buf.isEmpty { out.append(.text(buf)); buf = "" }
        }
        /// 从 from 开始找 close，返回 close 起点下标；跳过被反斜杠转义的字符
        func find(_ close: [Character], from: Int) -> Int? {
            var j = from
            while j + close.count <= c.count {
                if c[j] == "\\" && close.first != "\\" { j += 2; continue }
                if Array(c[j..<(j + close.count)]) == close { return j }
                j += 1
            }
            return nil
        }

        while i < c.count {
            let ch = c[i]
            // `代码` 里的 $ 不是公式（正则表达式的 ^…$ 等），整段原样交给 Markdown；没有配对的反引号按普通字符
            if ch == "`", let close = c[(i + 1)...].firstIndex(where: { $0 == "`" || $0 == "\n" }), c[close] == "`" {
                buf += String(c[i...close]); i = close + 1; continue
            }
            // 转义的 \$ 保留原样，交给 Markdown 处理
            if ch == "\\", i + 1 < c.count, c[i + 1] == "$" {
                buf.append("\\$"); i += 2; continue
            }
            if ch == "\\", i + 1 < c.count, c[i + 1] == "(" || c[i + 1] == "[" {
                let display = c[i + 1] == "["
                let close: [Character] = display ? ["\\", "]"] : ["\\", ")"]
                if let end = find(close, from: i + 2) {
                    let body = String(c[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        flush(); out.append(.math(body, display: display))
                        i = end + 2; continue
                    }
                }
            }
            if ch == "$" {
                if i + 1 < c.count, c[i + 1] == "$" {
                    if let end = find(["$", "$"], from: i + 2) {
                        let body = String(c[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !body.isEmpty {
                            flush(); out.append(.math(body, display: true))
                            i = end + 2; continue
                        }
                    }
                } else if i + 1 < c.count, !c[i + 1].isWhitespace, let end = inlineEnd(c, from: i + 1) {
                    flush(); out += breakable(String(c[(i + 1)..<end]))
                    i = end + 1; continue
                }
            }
            buf.append(ch)
            i += 1
        }
        flush()
        return out
    }

    /// 行内公式排成一张图，不能折行：推导链、长等式（E ⇒ E+E ⇒ id+E ⇒ …）会超出版面。
    /// 较长的公式在最外层的关系符（=、⇒、→、≤ 等）前切开，各段之间放一个零宽空格，正文就能在这里换行。
    /// 后面各段以关系符开头，前面补 {}，关系符前的空白照常排出。括号、\left…\right、\text{} 和环境里的不切
    static func breakable(_ latex: String) -> [MathSegment] {
        let c = Array(latex)
        guard c.count >= minBreakLength else { return [.math(latex, display: false)] }
        var cuts: [Int] = []
        var depth = 0  // 花括号、圆括号、方括号、\{ \}、\left \right、\begin \end 的总层数
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                var j = i + 1
                while j < c.count, c[j].isASCII, c[j].isLetter { j += 1 }
                if j == i + 1 {
                    // \{ \} 是集合括号；其他转义字符（\$、\,）跳过
                    if j < c.count, c[j] == "{" { depth += 1 } else if j < c.count, c[j] == "}" { depth -= 1 }
                    i = j + 1; continue
                }
                let name = String(c[(i + 1)..<j])
                if name == "left" || name == "begin" { depth += 1 } else if name == "right" || name == "end" { depth -= 1 }
                if depth == 0, i > 0, breakRelations.contains(name) || (name.hasPrefix("x") && name.hasSuffix("arrow"))
                    || (["overset", "underset", "stackrel"].contains(name) && stacksArrow(c, from: j)) {
                    cuts.append(i)
                }
                i = j; continue
            }
            switch ch {
            case "{", "(", "[": depth += 1
            case "}", ")", "]": depth -= 1
            case "=", "<", ">": if depth == 0, i > 0 { cuts.append(i) }
            default: break
            }
            i += 1
        }
        guard !cuts.isEmpty else { return [.math(latex, display: false)] }
        var out: [MathSegment] = []
        var start = 0
        for cut in cuts + [c.count] {
            let piece = String(c[start..<cut]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty {
                if !out.isEmpty { out.append(.text("\u{200B}")) }
                out.append(.math(start == 0 ? piece : "{}" + piece, display: false))
            }
            start = cut
        }
        return out
    }

    /// 少于这么多字符的公式不切
    static let minBreakLength = 40
    private static let breakRelations: Set<String> = [
        "Rightarrow", "Leftarrow", "Leftrightarrow", "to", "rightarrow", "leftarrow", "leftrightarrow",
        "longrightarrow", "Longrightarrow", "longleftarrow", "Longleftarrow", "implies", "iff", "mapsto",
        "le", "leq", "ge", "geq", "neq", "ne", "approx", "equiv",
    ]

    /// \overset{…}{底}：底是箭头时算关系符
    private static func stacksArrow(_ c: [Character], from: Int) -> Bool {
        var k = from, braces = 0, args = 0, base = ""
        while k < c.count, args < 2 {
            if c[k] == "{" { braces += 1 } else if c[k] == "}" { braces -= 1; if braces == 0 { args += 1 } } else if args == 1 { base.append(c[k]) }
            k += 1
        }
        return base.contains("arrow") || base.contains("\\to")
    }

    /// 行内 $…$ 的结束位置：前一个字符不是空白，后面不紧跟阿拉伯数字（避免把 $5 和 $10 当成公式），不跨空行。
    /// 只看 ASCII 数字：Character.isNumber 对「一」「二」「十」等汉字数字也是真，$P_1$一旦 会被当成没有结束
    private static func inlineEnd(_ c: [Character], from: Int) -> Int? {
        var j = from
        while j < c.count {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "\n", j + 1 < c.count, c[j + 1] == "\n" { return nil }
            if c[j] == "$" {
                let prevOK = !c[j - 1].isWhitespace
                let nextOK = j + 1 >= c.count || !(c[j + 1].isASCII && c[j + 1].isNumber)
                return prevOK && nextOK && j > from ? j : nil
            }
            j += 1
        }
        return nil
    }
}
