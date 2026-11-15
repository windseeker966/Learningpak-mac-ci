import Foundation

// 知识点掌握度：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/{Mastery,FSRS,SubjectiveAssessmentRules,ErrorTypes}.swift Tests/MasteryTests.swift -o /tmp/mastery-tests
// /tmp/mastery-tests
@main
private enum MasteryTests {
    static let known: Set<String> = ["K1", "K2", "K3"]

    static func choice(_ id: String, correct: Bool, _ c: ReviewEvidence.Confidence = .sure, weak: [String] = [],
                       immediate: Bool = false, tested: [String] = ["K1", "K2"]) -> Mastery.ChoiceAnswer {
        .init(questionID: id, isCorrect: correct, confidence: c, weakPoints: weak, isImmediateRedo: immediate,
              mainPoint: tested.first, testedPoints: tested)
    }

    static func stats(choice: [Mastery.ChoiceAnswer] = [], items: [Mastery.SubjectiveItem] = [],
                      subjective: [Mastery.SubjectiveAnswer] = [], variants: [Mastery.VariantAnswer] = [])
        -> [String: Mastery.Stat] {
        let list = Mastery.stats(choice: choice, subjectiveItems: items, subjective: subjective, variants: variants,
                                 knownPoints: known)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.pointID, $0) })
    }

    static func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

    static func main() {
        // 把握程度的折扣
        precondition(Mastery.confidenceFactor(.sure) == 1)
        precondition(Mastery.confidenceFactor(.unsure) == 0.6)
        precondition(Mastery.confidenceFactor(.guess) == 0.3)

        // 选择题：确定答对，主考权重 1、兼考 0.5，都记满分
        var s = stats(choice: [choice("Q1", correct: true)])
        precondition(close(s["K1"]?.mastery, 1) && close(s["K2"]?.mastery, 1))
        precondition(s["K1"]?.evidence.first?.weight == 1 && s["K2"]?.evidence.first?.weight == 0.5)

        // 只看最近一次（传入时新 → 旧）；看答案后立即重做的不算
        s = stats(choice: [choice("Q1", correct: true, immediate: true), choice("Q1", correct: false, weak: ["K1"]),
                           choice("Q1", correct: true)])
        precondition(s["K1"]?.evidence.count == 1 && close(s["K1"]?.mastery, 0), "最近一次（不算立即重做）答错")
        precondition(s["K1"]?.wrongCount == 1)

        // 答错时只计入选项暴露出的知识点
        precondition(s["K2"] == nil, "选项没暴露兼考知识点，不计入")

        // 犹豫、蒙对打折扣
        precondition(close(stats(choice: [choice("Q1", correct: true, .unsure)])["K1"]?.mastery, 0.6))
        precondition(close(stats(choice: [choice("Q1", correct: true, .guess)])["K1"]?.mastery, 0.3))

        // 答对时，选项暴露的知识点也按兼考计入
        s = stats(choice: [choice("Q1", correct: true, weak: ["K3"], tested: ["K1"])])
        precondition(s["K3"]?.evidence.first?.weight == 0.5 && close(s["K3"]?.mastery, 1))

        // 不在书里的知识点忽略
        precondition(stats(choice: [choice("Q1", correct: true, tested: ["K9"])]).isEmpty)

        // 加权平均：主考答对 1（权重 1）+ 兼考答错 0（权重 0.5）= 2/3
        s = stats(choice: [choice("Q1", correct: true, tested: ["K1"]),
                           choice("Q2", correct: false, weak: ["K1"], tested: ["K2", "K1"])])
        precondition(close(s["K1"]?.mastery, 2.0 / 3) && s["K1"]?.questionCount == 2 && s["K1"]?.wrongCount == 1)

        // 主观题：每一问看最近一次没跳过的自评；部分对算一半，再按把握程度打折
        let item = Mastery.SubjectiveItem(questionID: "S1", parts: [("（1）", ["K1"]), ("（2）", ["K2", "K3"])])
        func answer(_ r: [String: PartResult], _ c: ReviewEvidence.Confidence = .sure,
                    immediate: Bool = false) -> Mastery.SubjectiveAnswer {
            .init(questionID: "S1", confidence: c, isImmediateRedo: immediate, results: r)
        }
        s = stats(items: [item], subjective: [
            answer(["（1）": .partial, "（2）": .skipped]),
            answer(["（1）": .wrong, "（2）": .correct], .unsure),
        ])
        precondition(close(s["K1"]?.mastery, 0.5), "（1）看最近一次：部分对")
        precondition(close(s["K2"]?.mastery, 0.6), "（2）最近一次跳过，看上一次：犹豫答对")
        precondition(s["K3"]?.evidence.first?.weight == 0.5, "第二个知识点是兼考")
        precondition(s["K1"]?.wrongCount == 0, "部分对不算答错")
        s = stats(items: [item], subjective: [answer(["（1）": .correct], immediate: true), answer(["（1）": .wrong])])
        precondition(close(s["K1"]?.mastery, 0) && s["K1"]?.wrongCount == 1, "立即重做不算")
        s = stats(items: [item], subjective: [answer(["（1）": .correct], .guess)])
        precondition(close(s["K1"]?.mastery, 0.3), "不会做和蒙的一样打折")
        precondition(stats(items: [], subjective: [answer(["（1）": .correct])]).isEmpty, "已移除或废弃的题不计入")

        // AI 改编题：每道原题看最近一次，标记有问题的不算，计入原题考查的知识点
        func variant(_ score: Double?, flagged: Bool = false) -> Mastery.VariantAnswer {
            .init(originalID: "Q1", flagged: flagged, score: score, confidence: .sure, testedPoints: ["K1"])
        }
        s = stats(variants: [variant(1, flagged: true), variant(0), variant(1)])
        precondition(s["K1"]?.evidence.count == 1 && close(s["K1"]?.mastery, 0))
        precondition(s["K1"]?.evidence.first?.variant == true)
        precondition(stats(variants: [variant(nil), variant(1)]).isEmpty, "最近一次没有结果时不往前找")

        // 薄弱的在前；一样薄弱时做得多的在前
        let list = Mastery.stats(choice: [choice("Q1", correct: true, tested: ["K1"]),
                                          choice("Q2", correct: false, weak: ["K2"], tested: ["K2"]),
                                          choice("Q3", correct: false, weak: ["K3"], tested: ["K3"]),
                                          choice("Q4", correct: false, weak: ["K3"], tested: ["K3"])],
                                 subjectiveItems: [], subjective: [], variants: [], knownPoints: known)
        precondition(list.map(\.pointID) == ["K3", "K2", "K1"])

        print("MasteryTests passed")
    }
}
