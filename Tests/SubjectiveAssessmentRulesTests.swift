import Foundation

// 主观题自评的整理规则、把握程度的归档：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/{SubjectiveAssessmentRules,ErrorTypes,Confidence,FSRS}.swift Tests/SubjectiveAssessmentRulesTests.swift -o /tmp/subjective-assessment-tests
// /tmp/subjective-assessment-tests
@main
private enum SubjectiveAssessmentRulesTests {
    typealias Rules = SubjectiveAssessmentRules

    static func main() {
        // 整题结果
        precondition(PartResult.overall([.correct, .correct]) == .correct)
        precondition(PartResult.overall([.correct, .skipped]) == .correct, "跳过的小问不算")
        precondition(PartResult.overall([.blank, .blank]) == .blank)
        precondition(PartResult.overall([.wrong, .blank]) == .wrong)
        precondition(PartResult.overall([.correct, .wrong]) == .partial)
        precondition(PartResult.overall([.skipped]) == nil)

        precondition(Rules.needsCause(.partial) && Rules.needsCause(.wrong) && Rules.needsCause(.blank))
        precondition(!Rules.needsCause(.correct) && !Rules.needsCause(.skipped) && !Rules.needsCause(nil))

        // 多问：错因只记没做对的小问，错误类型按固定顺序；混淆的知识点只在选了「两个概念混淆了」时记
        let labels = ["（1）", "（2）", "（3）"]
        var form = Rules.Form()
        form.results = ["（1）": .correct, "（2）": .wrong, "（3）": .partial]
        form.causes = ["（1）": ["calculation"], "（2）": ["misread", "confused"], "（3）": ["calculation", "confused"]]
        form.notes = ["（2）": "  没看清  ", "（3）": "\n"]
        form.confused = ["（2）": ["K1", "K2"], "（3）": ["K2", "K3"]]
        var s = Rules.summarize(labels: labels, form: form)!
        precondition(s.results == [.correct, .wrong, .partial] && s.overall == .partial)
        precondition(s.causes.map(\.label) == ["（2）", "（3）"], "做对的小问不记错因")
        precondition(s.causes[0].errorTypes == ["confused", "misread"], "按 SubjectiveErrorType 的顺序")
        precondition(s.causes[0].note == "没看清" && s.causes[1].note == nil, "原因去掉首尾空白，空白算没写")
        precondition(s.errorTypes == ["confused", "calculation", "misread"], "整题错误类型是各问的合集，按固定顺序")
        precondition(s.errorNote == "（2） 没看清", "多问时原因加编号")
        precondition(s.confusedPoints == ["K1", "K2", "K3"], "去重、保序")

        form.causes["（2）"] = ["misread"]
        s = Rules.summarize(labels: labels, form: form)!
        precondition(s.causes[0].confusedPoints == nil, "没选混淆不记混淆的知识点")

        // 只有一问：原因不加编号；没选的小问记没做出来（正常流程提交前每问都已选）
        s = Rules.summarize(labels: ["全题"], form: Rules.Form(results: ["全题": .blank], notes: ["全题": "不会"]))!
        precondition(s.overall == .blank && s.errorNote == "不会")
        s = Rules.summarize(labels: ["（1）", "（2）"], form: Rules.Form(results: ["（1）": .correct]))!
        precondition(s.results == [.correct, .blank] && s.overall == .partial)
        precondition(Rules.summarize(labels: ["（1）"], form: Rules.Form(results: ["（1）": .skipped])) == nil)

        // 薄弱知识点：没做对的各问考查的知识点
        let weak = Rules.weakPoints(parts: [("（1）", ["K1"]), ("（2）", ["K2", "K1"]), ("（3）", ["K3"])],
                                    results: [.correct, .partial, .blank])
        precondition(weak == ["K2", "K1", "K3"])

        // 与 AI 结论不一致：跳过的和 AI 没给结论的不比
        let diff = Rules.aiDisagreements(labels: labels, results: [.correct, .skipped, .wrong],
                                         ai: ["（1）": .partial, "（2）": .correct])
        precondition(diff == ["（1）"])

        // 表单操作：勾选、取消
        var f = Rules.Form()
        f.toggleCause(.misread, part: "（1）")
        f.toggleCause(.other, part: "（1）")
        f.toggleCause(.misread, part: "（1）")
        precondition(f.causes["（1）"] == ["other"] && f.hasCause(.other, part: "（1）"))
        f.toggleConfused("K2", part: "（1）")
        f.toggleConfused("K1", part: "（1）")
        f.toggleConfused("K2", part: "（1）")
        precondition(f.confused["（1）"] == ["K1"] && f.isConfused("K1", part: "（1）"))

        // 能否提交：每问都要选结果，不能全是跳过；选了「其他原因」必须写原因
        f.results = ["（1）": .wrong]
        precondition(!f.canSubmit(labels: ["（1）", "（2）"]), "（2）没选")
        f.results["（2）"] = .correct
        precondition(f.causeLabels(["（1）", "（2）"]) == ["（1）"])
        precondition(!f.canSubmit(labels: ["（1）", "（2）"]), "选了其他原因没写")
        f.notes["（1）"] = "  "
        precondition(!f.canSubmit(labels: ["（1）", "（2）"]), "只有空白算没写")
        f.notes["（1）"] = "漏了条件"
        precondition(f.canSubmit(labels: ["（1）", "（2）"]))
        precondition(!Rules.Form(results: ["（1）": .skipped]).canSubmit(labels: ["（1）"]), "全是跳过")

        // 从记录还原
        let cause = PartCause(label: "（2）", errorTypes: ["misread"], note: "看错", confusedPoints: ["K1"])
        var r = Rules.Form(restoring: ["（1）", "（2）"], results: [.correct, .wrong], causes: [cause])
        precondition(r.results == ["（1）": .correct, "（2）": .wrong])
        precondition(r.causes == ["（2）": ["misread"]] && r.notes == ["（2）": "看错"] && r.confused == ["（2）": ["K1"]])
        // 旧记录只有整题错因：类型给每个没做对的小问，原因给第一个
        r = Rules.Form(restoring: ["（1）", "（2）", "（3）"], results: [.wrong, .correct, .blank], causes: [],
                       legacyErrorTypes: ["calculation"], legacyNote: "算错")
        precondition(r.causes == ["（1）": ["calculation"], "（3）": ["calculation"]] && r.notes == ["（1）": "算错"])

        // 记录里存的把握程度 → 三档
        precondition(ReviewEvidence.Confidence(stored: "sure") == .sure)
        precondition(ReviewEvidence.Confidence(stored: "guess") == .guess)
        precondition(ReviewEvidence.Confidence(stored: SubjectiveConfidence.gaveUp.rawValue) == .guess)
        precondition(ReviewEvidence.Confidence(stored: "unsure") == .unsure)
        precondition(ReviewEvidence.Confidence(stored: nil) == .unsure)

        print("SubjectiveAssessmentRulesTests passed")
    }
}
