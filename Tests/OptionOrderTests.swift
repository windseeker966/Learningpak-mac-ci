import Foundation

// 复习时打乱选项：
// swiftc -swift-version 6 -parse-as-library Learning/Rules/OptionOrder.swift Tests/OptionOrderTests.swift -o /tmp/option-order-tests
// /tmp/option-order-tests
@main
private enum OptionOrderTests {
    static func main() {
        var rng = SystemRandomNumberGenerator()
        let keys = ["A", "B", "C", "D"]
        let texts = ["A": "进程", "B": "线程", "C": "管程", "D": "作业"]

        for _ in 0..<200 {
            let o = OptionOrder.shuffled(keys: keys, texts: texts, stem: "下列哪个是调度的基本单位", using: &rng)
            precondition(o.isShuffled, "能打乱时一定和原顺序不同")
            precondition(o.keys.sorted() == keys)
            precondition(o.labels == keys, "显示字母按位置依次排下来")
            for k in keys { precondition(o.keys[keys.firstIndex(of: o.label(of: k))!] == k, "显示字母能换算回原题字母") }
        }

        // 「以上都不对」留在原位置
        var pinned = texts
        pinned["D"] = "以上选项都不对"
        for _ in 0..<100 {
            let o = OptionOrder.shuffled(keys: keys, texts: pinned, stem: "", using: &rng)
            precondition(o.isShuffled && o.keys[3] == "D" && o.label(of: "D") == "D")
        }

        // 引用了选项字母的题不打乱
        var refers = texts
        refers["D"] = "A和B都对"
        precondition(!OptionOrder.shuffled(keys: keys, texts: refers, stem: "", using: &rng).isShuffled)
        precondition(!OptionOrder.shuffled(keys: keys, texts: texts, stem: "关于选项A的说法", using: &rng).isShuffled)

        // 只剩一个能动的选项时不打乱
        let two = ["A": "对", "B": "以上都不对"]
        precondition(!OptionOrder.shuffled(keys: ["A", "B"], texts: two, stem: "", using: &rng).isShuffled)

        precondition(OptionOrder.mentionsOptions("A、C"))
        precondition(OptionOrder.mentionsOptions("选项 B 错误"))
        precondition(OptionOrder.mentionsOptions("C项"))
        precondition(!OptionOrder.mentionsOptions("进程A和进程B"))
        precondition(!OptionOrder.mentionsOptions("CPU和I/O"))
        precondition(OptionOrder.mentionsLetters("所以选B"))
        precondition(!OptionOrder.mentionsLetters("CPU 与 PCB"))

        // 按记录的顺序还原；对不上时不打乱
        let restored = OptionOrder(displayed: ["C", "A", "D", "B"], original: keys)
        precondition(restored.label(of: "C") == "A" && restored.label(of: "B") == "D")
        precondition(restored.labels(of: ["A", "B"]) == ["B", "D"])
        precondition(!OptionOrder(displayed: ["A", "B"], original: keys).isShuffled)

        // 讲评选项用当次显示编号，解析里明确的选项引用也应同步。
        precondition(restored.labels(of: ["C"]) == ["A"])
        precondition(restored.labels(of: ["A", "B"]) == ["B", "D"])
        let explanation = "选项C错误，A项正确。故选A。B正确，FIRST(A) 与 A→aB 是文法符号。"
        precondition(restored.relabelOptionReferences(in: explanation)
                     == "选项A错误，B项正确。故选B。D正确，FIRST(A) 与 A→aB 是文法符号。")
        precondition(OptionOrder(identity: keys).relabelOptionReferences(in: explanation) == explanation)

        print("OptionOrder tests passed")
    }
}
