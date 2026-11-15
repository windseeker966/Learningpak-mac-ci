#if DEBUG
import SwiftUI

/// 截图中的批改公式回归。只显示样例，不调用 AI，也不改写学习记录。
struct MathCompatibilityChecksView: View {
    private static let formulas = [
        #"\text{Start} \rightarrow \bigcirc \xrightarrow{(a|b)^*} \bigcirc \xrightarrow{ab} \bigcirc"#,
        #"\text{Start} \rightarrow \bigcirc \xrightarrow{(a|b)^*} \bigcirc \xrightarrow{a} \bigcirc \xrightarrow{b} \bigcirc"#,
        #"\text{Start} \rightarrow \bigcirc"#,
        #"\rightarrow \bigcirc \xrightarrow{a} \bigcirc \xrightarrow{b} \bigcirc"#,
        #"r = (a|b)^* ab"#,
        #"\varepsilon"#,
        #"\epsilon"#,
        #"x"#,
        // 讲解里直接写进 $…$ 的 Unicode 字符，SwiftMath 原本会静默丢掉
        #"M = ( S，Σ，δ，s₀，F )"#,
        #"S \times (Σ \cup \{\varepsilon\}) \to 2^S"#,
        #"\text{letter}\_（字母或下划线）"#,
        #"( ) \quad > \quad * \quad > \quad 连接 \quad > \quad |"#,
        #"0 \xrightarrow{(a|b)^*} ○ \xrightarrow{a} ○ \xrightarrow{b} …"#,
        #"\text{’\n’} \quad [ \t]+ \quad a \& b"#,
        // SwiftMath 缺、另行注册或改写的命令
        #"\text{RE} \dashrightarrow \text{NFA} \leadsto \text{DFA} \quad E \Coloneqq E + T \quad \llbracket e \rrbracket \triangleq v"#,
        #"x \xrightarrow[b]{a} y \quad a \not= b \quad \S 3 \ \checkmark \quad \sgn x \quad \dbinom{n}{k}"#,
        #"\color{red}{x} + \textcolor{blue}{y}"#
    ]
    @State private var result = "正在检查"
    private var sample: String {
        "## AI 批改公式回归\n\n" + result + "\n\n## 我看到的内容\n\n"
        + "- 第 1 行：$\(Self.formulas[0])$\n"
        + "- 第 2 行：$\(Self.formulas[1])$\n"
        + "- 第 3 行：$\(Self.formulas[2])$（该结点上方有自环标记 $a|b$）$\(Self.formulas[3])$\n"
        + "- 第 4 行：$\(Self.formulas[2])$（该结点上方有自环标记 $a$，下方有自环标记 $b$）$\(Self.formulas[3])$\n\n"
        + "## 对照参考答案\n\n题目要求为正则表达式 $\(Self.formulas[4])$ 构造 NFA。按星号展开时引入 $\(Self.formulas[5])$ 转换。\n\n"
        + "## 只有 x 高度的单个字母（下半部分不能被裁掉）\n\n"
        + "带 $\(Self.formulas[5])$ 边的 NFA、$\(Self.formulas[6])$-NFA、变量 $\(Self.formulas[7])$ 与 $r$、$y$、$\\alpha$。\n\n"
        + "## 非 ASCII 字符与补充的命令\n\n"
        + Self.formulas[8...].map { "- $\($0)$" }.joined(separator: "\n")
    }
    var body: some View {
        ScrollView {
            MarkdownView(text: sample).padding(24)
        }
        .task {
            let successes = Self.formulas.filter {
                MathRenderer.render($0, fontSize: 20, color: .label, display: false, scale: 2) != nil
            }.count
            result = "公式排版通过：\(successes)/\(Self.formulas.count)"
            print("Math compatibility rendering checks: \(successes)/\(Self.formulas.count)")
            precondition(successes == Self.formulas.count, "截图中的批改公式必须全部排版成功")
        }
    }
}
#endif
