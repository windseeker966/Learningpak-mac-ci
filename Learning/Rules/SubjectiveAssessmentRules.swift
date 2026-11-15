import Foundation

/// 主观题一问的自评结果
nonisolated enum PartResult: String, CaseIterable, Codable, Sendable {
    case correct, partial, wrong, blank
    /// 复习时跳过了上次已做对的小问
    case skipped

    var label: String {
        switch self {
        case .correct: "对"
        case .partial: "部分对"
        case .wrong: "错"
        case .blank: "没做出来"
        case .skipped: "跳过"
        }
    }

    /// 计入掌握度的得分；跳过的不计
    var score: Double? {
        switch self {
        case .correct: 1
        case .partial: 0.5
        case .wrong, .blank: 0
        case .skipped: nil
        }
    }

    /// 整题结果：都对为对，都没做出来为没做出来，只有错和没做出来为错，其余为部分对。跳过的小问不算
    static func overall(_ results: [PartResult]) -> PartResult? {
        let done = results.filter { $0 != .skipped }
        guard !done.isEmpty else { return nil }
        if done.allSatisfy({ $0 == .correct }) { return .correct }
        if done.allSatisfy({ $0 == .blank }) { return .blank }
        if done.allSatisfy({ $0 == .wrong || $0 == .blank }) { return .wrong }
        return .partial
    }
}

/// 某一问没做对的原因
nonisolated struct PartCause: Codable, Equatable {
    var label: String
    /// SubjectiveErrorType.rawValue
    var errorTypes: [String]
    var note: String?
    /// 选「两个概念混淆了」时指出的知识点（K- id）
    var confusedPoints: [String]? = nil

    /// 「（1）两个概念混淆了（A ↔ B）、审题错误：原因」；只有一问（全题）时不写编号
    func line(single: Bool, _ pointTitle: (String) -> String) -> String {
        let types = errorTypes.compactMap(SubjectiveErrorType.init(rawValue:)).map { t in
            if t == .confused, let points = confusedPoints, !points.isEmpty {
                return "\(t.label)（\(points.map(pointTitle).joined(separator: " ↔ "))）"
            }
            return t.label
        }.joined(separator: "、")
        let body = [types.isEmpty ? nil : types, note].compactMap { $0 }.joined(separator: "：")
        return single ? body : "\(label) \(body)"
    }
}

/// 主观题自评（原题和 AI 改编题共用）：把自评表单整理成要写入作答记录的内容
nonisolated enum SubjectiveAssessmentRules {
    /// 自评表单，都按小问编号：各问结果、勾选的错误类型（SubjectiveErrorType.rawValue）、写的原因、混淆的知识点
    struct Form: Equatable {
        var results: [String: PartResult] = [:]
        var causes: [String: Set<String>] = [:]
        var notes: [String: String] = [:]
        var confused: [String: [String]] = [:]

        /// 去掉首尾空白的原因；没写为空串
        func note(_ label: String) -> String {
            (notes[label] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct Summary: Equatable {
        /// 与小问一一对应；没选的记没做出来
        var results: [PartResult]
        var overall: PartResult
        /// 要写错因的小问（部分对、错、没做出来）各自的错因
        var causes: [PartCause]
        /// 各问错误类型的合集，按 SubjectiveErrorType 的顺序；统计和旧代码照常使用整题的错误类型
        var errorTypes: [String]
        /// 各问写的原因，多问时加编号，用「；」连接；都没写为 nil
        var errorNote: String?
        /// 各问混淆的知识点合集（去重、保序）
        var confusedPoints: [String]
    }

    /// 这一问要写错因：部分对、错、没做出来
    static func needsCause(_ r: PartResult?) -> Bool {
        r == .partial || r == .wrong || r == .blank
    }

    /// 整理自评表单；没有一问可计入（全部跳过）时为 nil
    static func summarize(labels: [String], form: Form) -> Summary? {
        let results = labels.map { form.results[$0] ?? .blank }
        guard let overall = PartResult.overall(results) else { return nil }
        let allTypes = SubjectiveErrorType.allCases.map(\.rawValue)
        let causes = labels.filter { needsCause(form.results[$0]) }.map { label in
            let types = allTypes.filter { form.causes[label]?.contains($0) ?? false }
            let confused = types.contains(SubjectiveErrorType.confused.rawValue) ? form.confused[label] ?? [] : []
            let note = form.note(label)
            return PartCause(label: label, errorTypes: types, note: note.isEmpty ? nil : note,
                             confusedPoints: confused.isEmpty ? nil : confused)
        }
        var confused: [String] = []
        for id in causes.flatMap({ $0.confusedPoints ?? [] }) where !confused.contains(id) { confused.append(id) }
        let notes = causes.compactMap { c in c.note.map { labels.count == 1 ? $0 : "\(c.label) \($0)" } }
        return Summary(results: results, overall: overall, causes: causes,
                       errorTypes: allTypes.filter { t in causes.contains { $0.errorTypes.contains(t) } },
                       errorNote: notes.isEmpty ? nil : notes.joined(separator: "；"),
                       confusedPoints: confused)
    }

    /// 原题的薄弱知识点：没做对（部分对、错、没做出来）的各问考查的知识点（去重、保序）
    static func weakPoints(parts: [(label: String, testedPoints: [String])], results: [PartResult]) -> [String] {
        var weak: [String] = []
        for (p, r) in zip(parts, results) where needsCause(r) {
            for id in p.testedPoints where !weak.contains(id) { weak.append(id) }
        }
        return weak
    }

    /// 自评与 AI 批改结论不一致的小问；跳过的和 AI 没给结论的不比
    static func aiDisagreements(labels: [String], results: [PartResult], ai: [String: PartResult]) -> [String] {
        zip(labels, results).compactMap { label, r in
            guard r != .skipped, let verdict = ai[label] else { return nil }
            return verdict == r ? nil : label
        }
    }
}

extension SubjectiveAssessmentRules.Form {
    func hasCause(_ type: SubjectiveErrorType, part label: String) -> Bool {
        causes[label]?.contains(type.rawValue) ?? false
    }

    mutating func toggleCause(_ type: SubjectiveErrorType, part label: String) {
        if hasCause(type, part: label) { causes[label]?.remove(type.rawValue) }
        else { causes[label, default: []].insert(type.rawValue) }
    }

    func isConfused(_ point: String, part label: String) -> Bool {
        confused[label]?.contains(point) ?? false
    }

    mutating func toggleConfused(_ point: String, part label: String) {
        if isConfused(point, part: label) { confused[label]?.removeAll { $0 == point } }
        else { confused[label, default: []].append(point) }
    }

    /// 要写错因的小问
    func causeLabels(_ labels: [String]) -> [String] {
        labels.filter { SubjectiveAssessmentRules.needsCause(results[$0]) }
    }

    /// 可以提交：每一问都选了结果，且不全是跳过；选了「其他原因」的小问必须写原因
    func canSubmit(labels: [String]) -> Bool {
        let picked = labels.compactMap { results[$0] }
        guard picked.count == labels.count, PartResult.overall(picked) != nil else { return false }
        return causeLabels(labels).allSatisfy { !hasCause(.other, part: $0) || !note($0).isEmpty }
    }

    /// 从已提交的自评还原表单。旧记录没有各问的错因，只有整题的：类型放到每个没做对的小问，原因放在第一个
    init(restoring labels: [String], results: [PartResult], causes: [PartCause],
         legacyErrorTypes: [String] = [], legacyNote: String? = nil) {
        for (label, r) in zip(labels, results) { self.results[label] = r }
        if !causes.isEmpty {
            for c in causes {
                self.causes[c.label] = Set(c.errorTypes)
                notes[c.label] = c.note
                confused[c.label] = c.confusedPoints
            }
        } else {
            let wrong = zip(labels, results).filter { SubjectiveAssessmentRules.needsCause($0.1) }.map(\.0)
            for label in wrong { self.causes[label] = Set(legacyErrorTypes) }
            if let first = wrong.first { notes[first] = legacyNote }
        }
    }
}
