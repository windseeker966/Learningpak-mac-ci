import Foundation
import SwiftMath

/// SwiftMath 不认识的常见 LaTeX 命令，在排版前改写成它支持的等价写法
nonisolated enum LatexCompat {
    /// SwiftMath 缺少、但讲解里常见的符号（编译原理的 ::=、⇢ 等），注册成同类型的原子，字形都在 XITS 里
    private static var extraSymbols: [(String, MTMathAtomType, String)] { [
        ("dashrightarrow", .relation, "\u{21E2}"), ("dashleftarrow", .relation, "\u{21E0}"),
        ("leadsto", .relation, "\u{21DD}"), ("rightsquigarrow", .relation, "\u{21DD}"),
        ("coloneqq", .relation, "\u{2254}"), ("Coloneqq", .relation, "\u{2A74}"),
        ("triangleq", .relation, "\u{225C}"), ("twoheadrightarrow", .relation, "\u{21A0}"),
        ("rightharpoonup", .relation, "\u{21C0}"), ("rightleftharpoons", .relation, "\u{21CC}"),
        ("nrightarrow", .relation, "\u{219B}"), ("nleftarrow", .relation, "\u{219A}"),
        ("vartriangleleft", .binaryOperator, "\u{22B2}"),
        ("S", .ordinary, "\u{00A7}"), ("checkmark", .ordinary, "\u{2713}"), ("blacksquare", .ordinary, "\u{25A0}"),
        ("surd", .ordinary, "\u{221A}"), ("complement", .ordinary, "\u{2201}"),
        ("llbracket", .open, "\u{27E6}"), ("rrbracket", .close, "\u{27E7}"),
    ] }

    /// MTMathAtom 的构造函数不公开：复制一个同类型的现成符号，换掉字符
    private static func atom(_ type: MTMathAtomType, _ value: String) -> MTMathAtom {
        let template: String
        switch type {
        case .relation: template = "to"
        case .binaryOperator: template = "times"
        case .open: template = "langle"
        case .close: template = "rangle"
        default: template = "infty"
        }
        let a = MTMathAtomFactory.atom(forLatexSymbol: template)!
        a.type = type
        a.nucleus = value
        return a
    }

    /// 带上下标的箭头（S \Rightarrow_{lm} α、\overset{*}{\Rightarrow}、\xrightarrow{a}）：SwiftMath 把箭头上的上下标
    /// 排在箭头右边、中间还空出一大截，看上去像标在后一个符号上。改成带上下限的大型运算符，标注就叠在箭头正上方、正下方。
    /// 箭头两边各加一个窄空格：多于一个字符的运算符不会被放大，也补上关系符两边的空白
    private static let stackedArrows: [String: String] = [
        "to": "\u{2192}", "rightarrow": "\u{2192}", "Rightarrow": "\u{21D2}", "leftarrow": "\u{2190}", "Leftarrow": "\u{21D0}",
        "leftrightarrow": "\u{2194}", "Leftrightarrow": "\u{21D4}", "longrightarrow": "\u{27F6}",
        "Longrightarrow": "\u{27F9}", "longleftarrow": "\u{27F5}", "Longleftarrow": "\u{27F8}", "mapsto": "\u{21A6}",
    ]
    private static func stackedName(_ arrow: String) -> String { "stacked" + arrow }

    /// SwiftMath 缺少的积分号（曲面积分的闭曲面积分号等），和它自带的 \oint 一样注册成单个字符的大型运算符，字形都在 XITS 里
    private static let extraIntegrals: [String: String] = ["oiint": "\u{222F}", "oiiint": "\u{2230}"]

    /// 启动时调用一次（在主线程），之后排版才认得 extraSymbols、extraIntegrals、叠放标注的箭头和 \sgn
    static func registerSymbols() {
        for (name, type, value) in extraSymbols where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            MTMathAtomFactory.add(latexSymbol: name, value: atom(type, value))
        }
        for (name, glyph) in extraIntegrals where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            MTMathAtomFactory.add(latexSymbol: name, value: MTMathAtomFactory.operatorWithName(glyph, limits: false))
        }
        for (arrow, glyph) in stackedArrows where MTMathAtomFactory.atom(forLatexSymbol: stackedName(arrow)) == nil {
            MTMathAtomFactory.add(latexSymbol: stackedName(arrow),
                                  value: MTMathAtomFactory.operatorWithName("\u{2009}\(glyph)\u{2009}", limits: true))
        }
        if MTMathAtomFactory.atom(forLatexSymbol: "sgn") == nil {
            MTMathAtomFactory.add(latexSymbol: "sgn", value: MTMathAtomFactory.operatorWithName("sgn", limits: false))
        }
    }

    /// 无参数命令：原命令 → 替换（命令后不能紧跟字母，避免 \dotsx 之类误伤）
    private static let simple: [(String, String)] = [
        ("\\dotsc", "\\ldots"), ("\\dotso", "\\ldots"), ("\\dotsb", "\\cdots"), ("\\dotsm", "\\cdots"),
        ("\\dotsi", "\\cdots"), ("\\dots", "\\ldots"),
        ("\\lvert", "|"), ("\\rvert", "|"), ("\\lVert", "\\|"), ("\\rVert", "\\|"),
        ("\\because", "\\text{∵}"), ("\\therefore", "\\text{∴}"),
        ("\\bmod", "\\mathrm{mod}"), ("\\middle", ""),
        ("\\bigcirc", "\\text{◯}"),
        ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\dbinom", "\\binom"), ("\\tbinom", "\\binom"),
        ("\\emph", "\\textit"), ("\\hline", ""),
    ]
    /// 带参数的命令：返回参数个数与用参数拼出替换的方法
    private static func argRule(_ name: String) -> (Int, ([String]) -> String)? {
        switch name {
        case "overset", "stackrel": return (2, { a in "\(stackBase(a[1]))^{\(a[0])}" })
        case "underset": return (2, { a in "\(stackBase(a[1]))_{\(a[0])}" })
        case "xrightarrow": return (1, { a in "\\\(stackedName("longrightarrow"))^{\(a[0])}" })
        case "xleftarrow": return (1, { a in "\\\(stackedName("longleftarrow"))^{\(a[0])}" })
        case "xrightarrowbelow": return (2, { a in "\\\(stackedName("longrightarrow"))^{\(a[1])}_{\(a[0])}" })
        case "xleftarrowbelow": return (2, { a in "\\\(stackedName("longleftarrow"))^{\(a[1])}_{\(a[0])}" })
        case "overbrace": return (1, { a in "\\overline{\(a[0])}" })
        case "underbrace": return (1, { a in "\\underline{\(a[0])}" })
        case "boxed", "cancel", "mathop": return (1, { a in "{\(a[0])}" })
        case "fbox": return (1, { a in "\\text{\(a[0])}" })
        case "phantom": return (1, { _ in "\\ " })
        case "hspace", "hspace*": return (1, { _ in "\\quad " })
        case "tag": return (1, { a in "\\qquad (\(a[0]))" })
        default: return nil
        }
    }

    static func rewrite(_ latex: String) -> String {
        var s = latex
        // 下划线后紧跟右括号、竖线、逗号或结尾时不会是下标，是漏写了转义：(.|_) 应为 (.|\_)
        s = s.replacingOccurrences(of: #"(?<!\\)_(?=\s*(?:[)\]}|,;]|$))"#, with: #"\\_"#, options: .regularExpression)
        // \: \> 是中等空白，SwiftMath 只有 \, \; \!
        s = s.replacingOccurrences(of: "\\:", with: "\\;").replacingOccurrences(of: "\\>", with: "\\;")
        // & 在 SwiftMath 里总是表格分列（\text 里也是），只能换成全角 ＆
        s = s.replacingOccurrences(of: "\\&", with: "\\text{＆}")
        s = s.replacingOccurrences(of: #"\\not\s*="#, with: #"\\neq "#, options: .regularExpression)
        // 讲解里写进公式的转义字符 '\n'、[ \t]+：按字面显示反斜杠（\\ 换行不受影响）
        s = s.replacingOccurrences(of: #"(?<!\\)\\([ntr])(?![A-Za-z])"#, with: #"\\backslash $1"#,
                                   options: .regularExpression)
        // \verb|x| → \texttt{x}（分隔符可以是任意字符）
        s = s.replacingOccurrences(of: #"\\verb\*?([^A-Za-z\s])(.*?)\1"#, with: #"\\texttt{$2}"#, options: .regularExpression)
        // \xrightarrow[下]{上}：带下方标注的可选参数
        s = s.replacingOccurrences(of: #"\\x(right|left)arrow\s*\[([^\]]*)\]\s*\{"#, with: #"\\x$1arrowbelow{$2}{"#,
                                   options: .regularExpression)
        // SwiftMath 排不出带颜色的内容（整段空白），去掉颜色只留内容：\color{red}{x}、\textcolor{red}{x}、{\color{red} x}
        s = s.replacingOccurrences(of: #"\\(?:text)?color\s*\{[^}]*\}"#, with: "", options: .regularExpression)
        // SwiftMath 只有 aligned，没有 align / align*
        s = s.replacingOccurrences(of: #"\\(begin|end)\{align\*?\}"#, with: #"\\$1{aligned}"#, options: .regularExpression)
        // array 环境：去掉列格式，改成 matrix
        s = s.replacingOccurrences(of: #"\\begin\{array\}\{[^}]*\}"#, with: "\\\\begin{matrix}", options: .regularExpression)
            .replacingOccurrences(of: "\\end{array}", with: "\\end{matrix}")
        for (from, to) in simple {
            let pattern = NSRegularExpression.escapedPattern(for: from) + "(?![A-Za-z])"
            s = s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: to),
                                       options: .regularExpression)
        }
        return unicodeToMath(primes(stackArrows(rewriteArgs(s))))
    }

    private static let primeCount: [Character: Int] = ["'": 1, "′": 1, "″": 2, "‴": 3]

    /// SwiftMath 会静默丢掉数学模式里的 '，而 ^{\prime} 排出来又太高、离字母太远（XITS 的 ′ 字形本身就在上标高度，
    /// 再当上标抬一次就高了，斜体字母的倾斜修正还把它往右推）。改成直接跟在后面的 \prime：T' → T\prime，
    /// T'' → T\prime\prime，f'^{2} → f\prime ^{2}（上标照常挂在 ′ 后面）。\text{…} 里的不动。
    /// SwiftMath 不加斜体修正，右上角往外伸的大写字母（T 的一横、F、P、V 的右上角）会盖住 ′，这些字母后先空一个 \,
    private static let overhangLetters: Set<Character> = ["C", "E", "F", "P", "S", "T", "U", "V", "W", "X", "Y", "Z"]

    static func primes(_ s: String) -> String {
        guard s.contains(where: { primeCount[$0] != nil }) else { return s }
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                var j = i + 1
                while j < c.count, c[j].isASCII, c[j].isLetter { j += 1 }
                if j == i + 1 { out.append(ch); if j < c.count { out.append(c[j]) }; i = j + 1; continue }
                let name = String(c[(i + 1)..<j])
                out += String(c[i..<j])
                i = j
                if name.hasPrefix("text") || name == "mbox" {
                    var k = j
                    while k < c.count, c[k] == " " { k += 1 }
                    if k < c.count, c[k] == "{", let end = matchBrace(c, k) { out += String(c[j...end]); i = end + 1 }
                }
                continue
            }
            var count = 0
            while i < c.count, let n = primeCount[c[i]] { count += n; i += 1 }
            if count == 0 { out.append(ch); i += 1; continue }
            // 单独的字母（不是 \LaTeX 这类命令的结尾）
            if let last = out.last, overhangLetters.contains(last),
               out.reversed().drop(while: { $0.isASCII && $0.isLetter }).first != "\\" {
                out += "\\,"
            }
            // 末尾的空格把命令和后面的字母隔开（f'x → f\prime x）
            out += String(repeating: "\\prime", count: count) + " "
        }
        return out
    }

    /// SwiftMath 在数学模式里会静默丢掉不认识的非 ASCII 字符（不报错，字符直接消失），
    /// 而讲解里常有直接写进 $…$ 的 Σ、δ、→、s₀、全角逗号、中文。
    /// 有对应命令的换成命令（\delta、\to），上下标数字换成 _{0}/^{2}，全角标点换成半角，
    /// 其余包进 \text{}（\text 里任意字符都能显示，中文走后备字体）。\text{…} 里的内容原样保留。
    static func unicodeToMath(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { !$0.isASCII }) else { return s }
        let c = Array(s)
        var out = ""
        var text = ""  // 待包进 \text{} 的字符
        func flushText() { if !text.isEmpty { out += "\\text{\(text)}"; text = "" } }
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                flushText()
                var j = i + 1
                while j < c.count, c[j].isASCII, c[j].isLetter { j += 1 }
                if j == i + 1 { out.append(ch); if j < c.count { out.append(c[j]) }; i = j + 1; continue }
                out += String(c[i..<j])
                // \text{…} 里的字符 SwiftMath 都收，原样跳过
                if String(c[(i + 1)..<j]) == "text" {
                    var k = j
                    while k < c.count, c[k] == " " { k += 1 }
                    if k < c.count, c[k] == "{", let end = matchBrace(c, k) {
                        out += String(c[j...end]); i = end + 1; continue
                    }
                }
                i = j
                continue
            }
            if ch.isASCII || MTMathAtomFactory.atom(forCharacter: ch) != nil {
                flushText(); out.append(ch); i += 1; continue
            }
            // 连续的下标／上标字符合成一组：s₀₁ → s_{01}
            if let (table, mark) = [(subscripts, "_"), (superscripts, "^")].first(where: { $0.0[ch] != nil }) {
                var run = ""
                while i < c.count, let v = table[c[i]] { run += v; i += 1 }
                flushText(); out += "\(mark){\(run)}"
                continue
            }
            if let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1, (0xFF01...0xFF5E).contains(v),
               let ascii = Unicode.Scalar(v - 0xFEE0), !"#$%&\\^_{}~".unicodeScalars.contains(ascii) {
                flushText(); out.unicodeScalars.append(ascii)
            } else if let name = MTMathAtomFactory.latexSymbolName(for: atom(.ordinary, String(ch))) {
                flushText(); out += "\\\(name) "
            } else {
                text.append(ch)
            }
            i += 1
        }
        flushText()
        return out
    }

    private static let subscripts: [Character: String] = Dictionary(uniqueKeysWithValues:
        zip("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₒₓₕₖₗₘₙₚₛₜᵢⱼ", ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", "=", "(", ")",
                                              "a", "e", "o", "x", "h", "k", "l", "m", "n", "p", "s", "t", "i", "j"]))
    private static let superscripts: [Character: String] = Dictionary(uniqueKeysWithValues:
        zip("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ", ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", "=", "(", ")", "n", "i"]))

    /// \overset、\underset 的底：箭头（或已经叠放过的箭头，如 \overset{*}{\underset{lm}{\Rightarrow}}）原样接上下标，
    /// 由 stackArrows 换成叠放的箭头；其他底加花括号再接上下标
    private static func stackBase(_ base: String) -> String {
        let b = base.trimmingCharacters(in: .whitespaces)
        if let m = b.wholeMatch(of: #/\\([A-Za-z]+)(?:_\{.*\})?/#), stackedArrows[String(m.1)] != nil || m.1.hasPrefix("stacked") {
            return b
        }
        return "{\(base)}"
    }

    /// 箭头后面紧跟上下标时换成叠放标注的箭头（见 stackedArrows）
    static func stackArrows(_ s: String) -> String {
        guard s.contains("_") || s.contains("^") else { return s }
        return s.replacing(#/\\([A-Za-z]+)(?=\s*[_^])/#) { m in
            stackedArrows[String(m.1)] != nil ? "\\\(stackedName(String(m.1)))" : String(m.0)
        }
    }

    /// 改写带花括号参数的命令；参数里可以嵌套花括号和其他命令
    private static func rewriteArgs(_ s: String) -> String {
        let c = Array(s)
        var out = ""
        var i = 0
        while i < c.count {
            if c[i] == "\\" {
                var j = i + 1
                while j < c.count, c[j].isLetter { j += 1 }
                var name = String(c[(i + 1)..<j])
                if j < c.count, c[j] == "*" { j += 1 }  // \tag*、\mathop* 之类
                if name.isEmpty { out.append(c[i]); if i + 1 < c.count { out.append(c[i + 1]) }; i += 2; continue }
                if let (count, make) = argRule(name) {
                    var args: [String] = []
                    var k = j
                    while args.count < count {
                        while k < c.count, c[k] == " " { k += 1 }
                        guard k < c.count, c[k] == "{", let end = matchBrace(c, k) else { break }
                        args.append(rewriteArgs(String(c[(k + 1)..<end])))
                        k = end + 1
                    }
                    if args.count == count {
                        out += make(args)
                        i = k
                        continue
                    }
                }
                name = ""
                out += String(c[i..<j])
                i = j
                continue
            }
            out.append(c[i])
            i += 1
        }
        return out
    }

    private static func matchBrace(_ c: [Character], _ open: Int) -> Int? {
        var depth = 0
        var k = open
        while k < c.count {
            if c[k] == "\\" { k += 2; continue }
            if c[k] == "{" { depth += 1 }
            if c[k] == "}" { depth -= 1; if depth == 0 { return k } }
            k += 1
        }
        return nil
    }
}
