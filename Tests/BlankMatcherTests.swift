import Foundation

// 填空题的答案比对：
// swiftc -swift-version 6 -parse-as-library Learning/Rules/BlankMatcher.swift Tests/BlankMatcherTests.swift -o /tmp/blank-tests
// /tmp/blank-tests
@main
private enum BlankMatcherTests {
    static func main() {
        let m = BlankMatcher.matches
        precondition(m("进程控制块", ["进程控制块", "PCB"]))
        precondition(m(" pcb ", ["进程控制块", "PCB"]), "大小写、首尾空格不影响")
        precondition(m("ＰＣＢ", ["PCB"]), "全角字母转半角")
        precondition(m("进程 控制块。", ["进程控制块"]), "中间空格、末尾句号不影响")
        precondition(!m("进程控制", ["进程控制块"]))
        precondition(!m("", ["0"]), "没填不算对")
        precondition(!m("   ", ["0"]))

        // 数值
        precondition(m("25", ["25"]))
        precondition(m("25.0", ["25"]), "数值相等即可")
        precondition(m(".5", ["0.5"]))
        precondition(m("1/2", ["0.5"]), "分数与小数")
        precondition(m("2/4", ["1/2"]))
        precondition(m("-3", ["-3.00"]))
        precondition(m("２５", ["25"]), "全角数字")
        precondition(!m("0.33", ["1/3"]), "近似值不算一致，交给 AI 和自评")
        precondition(!m("25ms", ["25"]), "带单位的不按数值比，交给 AI 和自评")
        precondition(m("25ms", ["25", "25ms"]))
        precondition(!m("1/0", ["1/0x"]))

        // 公式写法：包裹的 $ 和空格去掉后逐字比较
        precondition(m("$x^2$", ["x^2"]))
        precondition(m("x ^ 2", ["x^2"]))
        precondition(!m("x^3", ["x^2"]))

        precondition(BlankMatcher.isEmpty(" 。"))
        print("BlankMatcher tests passed")
    }
}
