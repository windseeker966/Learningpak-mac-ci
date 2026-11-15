import Foundation

/// 知识点掌握度：按每道题最近一次作答计算，主考权重高于兼考。确定答对算掌握，犹豫或蒙对打折扣；
/// 选择题答错时只计入选项暴露出的知识点。主观题按每一问最近一次自评计入，部分对算一半；
/// AI 改编题按原题最近一次改编题的结果计入（改编题标记有错的不算）。看答案后不久的重做不算
nonisolated enum Mastery {
    /// 一条掌握度证据：某道题（或某一问、某道改编题）最近一次的结果
    struct Evidence: Equatable, Sendable {
        let questionKey: String
        let score: Double
        let weight: Double
        let wrong: Bool
        /// 来自 AI 改编题（计入原题）
        var variant = false
    }

    struct Stat: Equatable, Sendable {
        let pointID: String
        var evidence: [Evidence] = []

        /// 加权平均：主考权重 1，兼考 0.5
        var mastery: Double {
            let weight = evidence.reduce(0) { $0 + $1.weight }
            return weight > 0 ? evidence.reduce(0) { $0 + $1.weight * $1.score } / weight : 0
        }

        var questionCount: Int { Set(evidence.map(\.questionKey)).count }
        var wrongCount: Int { Set(evidence.filter(\.wrong).map(\.questionKey)).count }
    }

    /// 选择题的一次作答，连同题目考查的知识点
    struct ChoiceAnswer: Sendable {
        var questionID: String
        var isCorrect: Bool
        var confidence: ReviewEvidence.Confidence
        /// 所选选项暴露的知识点，答对时为空
        var weakPoints: [String]
        var isImmediateRedo: Bool
        /// 题目的主考知识点
        var mainPoint: String?
        /// 题目考查的知识点，主考在前
        var testedPoints: [String]
    }

    /// 一道主观题和各问考查的知识点（主考在前）
    struct SubjectiveItem: Sendable {
        var questionID: String
        var parts: [(label: String, testedPoints: [String])]
    }

    /// 主观题的一次已自评作答
    struct SubjectiveAnswer: Sendable {
        var questionID: String
        var confidence: ReviewEvidence.Confidence
        var isImmediateRedo: Bool
        /// 各问的自评结果
        var results: [String: PartResult]
    }

    /// AI 改编题的一次作答，连同原题考查的知识点
    struct VariantAnswer: Sendable {
        var originalID: String
        var flagged: Bool
        /// 整题结果的得分；没有结果时为 nil
        var score: Double?
        var confidence: ReviewEvidence.Confidence
        var testedPoints: [String]
    }

    /// 把握程度对得分的折扣：确定 1，犹豫 0.6，蒙的 / 不会做 0.3
    static func confidenceFactor(_ c: ReviewEvidence.Confidence) -> Double {
        switch c {
        case .sure: 1
        case .unsure: 0.6
        case .guess: 0.3
        }
    }

    /// 各知识点的掌握度，薄弱的在前。作答都按时间倒序（新 → 旧）传入；不在 knownPoints 里的知识点忽略
    static func stats(choice: [ChoiceAnswer], subjectiveItems: [SubjectiveItem], subjective: [SubjectiveAnswer],
                      variants: [VariantAnswer], knownPoints: Set<String>) -> [Stat] {
        var stats: [String: Stat] = [:]
        func add(_ id: String, _ e: Evidence) {
            guard knownPoints.contains(id) else { return }
            stats[id, default: Stat(pointID: id)].evidence.append(e)
        }
        func addAll(_ ids: [String], key: String, score: Double, variant: Bool = false) {
            for (i, id) in ids.enumerated() {
                add(id, .init(questionKey: key, score: score, weight: i == 0 ? 1 : 0.5, wrong: score == 0, variant: variant))
            }
        }

        // 选择题：每道题只看最近一次作答；看答案后立即重做的不算证据。
        // 确定答对 1，犹豫答对 0.6，蒙对 0.3；答错时只计入选项暴露出的知识点，记 0
        var latest: [String: ChoiceAnswer] = [:]
        for a in choice where !a.isImmediateRedo && latest[a.questionID] == nil {
            latest[a.questionID] = a
        }
        for a in latest.values {
            if a.isCorrect {
                var ids = a.testedPoints
                for w in a.weakPoints where !ids.contains(w) { ids.append(w) }
                for id in ids {
                    add(id, .init(questionKey: a.questionID, score: confidenceFactor(a.confidence),
                                  weight: a.mainPoint == id ? 1 : 0.5, wrong: false))
                }
            } else {
                for id in a.weakPoints {
                    add(id, .init(questionKey: a.questionID, score: 0, weight: a.mainPoint == id ? 1 : 0.5, wrong: true))
                }
            }
        }

        // 主观题：每一问看最近一次（不算立即重做、跳过）的自评。对 1、部分对 0.5、错 0，再按把握程度打折
        for q in subjectiveItems {
            let tries = subjective.filter { $0.questionID == q.questionID && !$0.isImmediateRedo }
            for part in q.parts {
                guard let a = tries.first(where: { ($0.results[part.label] ?? .skipped) != .skipped }),
                      let base = a.results[part.label]?.score else { continue }
                addAll(part.testedPoints, key: q.questionID, score: base * confidenceFactor(a.confidence))
            }
        }

        // AI 改编题：每道原题看最近一次改编题的结果，计入原题考查的知识点
        var seen = Set<String>()
        for v in variants where !v.flagged && seen.insert(v.originalID).inserted {
            guard let base = v.score else { continue }
            addAll(v.testedPoints, key: v.originalID, score: base * confidenceFactor(v.confidence), variant: true)
        }
        return stats.values.sorted { ($0.mastery, -$0.questionCount) < ($1.mastery, -$1.questionCount) }
    }
}
