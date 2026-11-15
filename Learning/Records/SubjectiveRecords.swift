import CryptoKit
import Foundation
import PencilKit
import SwiftData

/// 主观题的一次作答：从开始写到对照答案自评。
/// 一道题同一时间只有一次进行中的作答；重做或下次复习时，上一次的页面笔迹存进 inkData，页面清空重写。
@Model
final class SubjectiveAttempt {
    var packID: String
    var sectionID: String
    var questionID: String
    /// learn（学习页第一次）| redo（学习页重做）| review（复习）
    var mode: String
    var createdAt: Date
    /// 看答案前标的把握程度（SubjectiveConfidence）；旧版本迁移来的记录为 nil
    var confidence: String?
    var revealedAt: Date?
    /// 看答案前的书写用时、看答案后的停留时间：只计 App 在前台、题目在屏幕上的时间
    var writingSeconds: Double = 0
    var feedbackSeconds: Double = 0
    /// 最后一次在屏幕上看到答案的时间
    var lastViewedAt: Date?
    /// 看答案前写下（看答案时仍在页面上）的笔画数，看答案后新写的笔画数
    var strokesBeforeReveal: Int = 0
    var strokesAfterReveal: Int = 0
    /// 自评时的小问编号和各问结果（PartResult），一一对应
    var partLabels: [String] = []
    var partResults: [String] = []
    /// 整题结果（PartResult，不会是 skipped）；nil 表示还没自评
    var result: String?
    var assessedAt: Date?
    /// 自评的错误类型（SubjectiveErrorType，可多选）和原因：各问错因的合集，按小问分开的见 partCauses
    var errorTypes: [String] = []
    var errorNote: String?
    /// 没做对的各问的错误类型和原因（JSON 编码的 [PartCause]）；旧记录为 nil，只有整题的 errorTypes / errorNote
    var partCausesData: Data?
    /// 自评「两个概念混淆了」时指出的知识点（K- id）：各问的合集，按小问分开的见 partCauses
    var confusedPoints: [String] = []
    /// 订正笔记：正确思路、下次要注意什么
    var correctionNote: String?
    var correctionUpdatedAt: Date?
    /// 订正笔记每次保存的内容（JSON 编码的 [CorrectionEntry]），按时间顺序
    var correctionHistoryData: Data?
    /// 订正笔记的手写：各书写区渲染成的 PNG（JSON 编码的 [Data]），和书写区数量
    var correctionInkData: Data?
    var correctionAreaCount: Int = 0
    /// 没做对的小问考查的知识点
    var weakPoints: [String] = []
    /// 自评时有可对照的 AI 批改；与 AI 结论不一致的小问
    var aiCompared: Bool = false
    var aiDisagreements: [String] = []
    /// 每次提交或修改自评的记录（JSON 编码的 [SubjectiveAssessment]）
    var assessmentHistoryData: Data?
    /// 这次作答的 AI 批改（JSON 编码的 [SavedGrading]）
    var gradingHistoryData: Data?
    /// 这次作答的综合题讲评和追问，与批改独立保存。
    var reviewConversationData: Data?
    /// 讲评时的图片快照单独存储，避免草稿保存时反复编码图片。
    @Attribute(.externalStorage) var reviewImagesData: Data?
    /// 键盘输入的填空题：各空填的内容，与 partLabels 无关，按题目的小问顺序
    var typedAnswers: [String] = []
    /// 键盘输入的填空题：提交时与答案一致、自动判对的空
    var autoMatched: [String] = []
    /// 这次作答结束后从页面移走的笔迹（PKDrawing 数据）；仍在页面上时为 nil
    var inkData: Data?
    /// 看过答案后收起了答案：重新打开时保持收起
    var answerHidden: Bool = false
    /// 在别的 App（如 GoodNotes）里写好、贴进来的作答图片（JSON 编码的 [PastedImage]），按贴入时间先后
    @Attribute(.externalStorage) var pastedImagesData: Data?
    /// 距上次看到这道题答案的秒数；第一次作答为 nil
    var sinceAnswerSeen: Double?
    var sessionID: String?
    var sessionIndex: Int = 0
    /// 在手机复习 App 上作答、同步过来的：手机上这条结果的 id（见 PhoneSyncImport）；iPad 上作答的为 nil
    var phoneID: String?
    /// 作答时的题目内容（JSON），教辅包更新后仍能还原
    var questionSnapshot: Data?
    /// 作答时题目内容（questionSnapshot）的哈希；早期记录为 nil，见 recordedHash
    var contentHash: String?

    init(packID: String, sectionID: String, questionID: String, mode: String) {
        self.packID = packID
        self.sectionID = sectionID
        self.questionID = questionID
        self.mode = mode
        self.createdAt = .now
    }

    var resultValue: PartResult? { result.flatMap(PartResult.init(rawValue:)) }
    var isImmediateRedo: Bool { (sinceAnswerSeen ?? .infinity) < AttemptRecord.immediateRedoInterval }

    /// 作答时题目内容的哈希；早期记录由题目快照算出
    var recordedHash: String? { contentHash ?? questionSnapshot.map(SubjectiveRecords.hash) }

    /// 各问错因，一问一行；旧记录只有整题的错误类型和原因
    func causeLines(_ pointTitle: (String) -> String) -> [String] {
        let causes = partCauses
        if !causes.isEmpty { return causes.map { $0.line(single: partLabels.count <= 1, pointTitle) } }
        let types = errorTypes.compactMap(SubjectiveErrorType.init(rawValue:)).map(\.label).joined(separator: "、")
        let line = [types.isEmpty ? nil : types, errorNote].compactMap { $0 }.joined(separator: "：")
        return line.isEmpty ? [] : [line]
    }

}

/// 主观题一次作答的记录：原题（SubjectiveAttempt）和 AI 改编题（VariantAttempt）用同一套作答流程
/// （SubjectiveAttemptSession）和显示（SubjectiveCard）
nonisolated protocol SubjectiveAttemptRecord: CorrectionNoted {
    var persistentModelID: PersistentIdentifier { get }
    var revealedAt: Date? { get set }
    var assessedAt: Date? { get set }
    var writingSeconds: Double { get set }
    var feedbackSeconds: Double { get set }
    var lastViewedAt: Date? { get set }
    var sinceAnswerSeen: Double? { get set }
    var strokesBeforeReveal: Int { get set }
    var strokesAfterReveal: Int { get set }
    var typedAnswers: [String] { get set }
    var autoMatched: [String] { get set }
    var answerHidden: Bool { get set }
    var inkData: Data? { get set }
    var pastedImagesData: Data? { get set }
    var gradingHistoryData: Data? { get set }
    var reviewConversationData: Data? { get set }
    var reviewImagesData: Data? { get set }
    var partLabels: [String] { get set }
    var partResults: [String] { get set }
    var partCausesData: Data? { get set }
    var assessmentHistoryData: Data? { get set }
    var errorTypes: [String] { get set }
    var errorNote: String? { get set }
    var confusedPoints: [String] { get set }
    var weakPoints: [String] { get set }
    var aiCompared: Bool { get set }
    var aiDisagreements: [String] { get set }
    /// 看答案前标的把握程度
    var confidenceValue: SubjectiveConfidence? { get set }
    /// 整题结果；nil 表示还没自评
    var overallResult: PartResult? { get set }
    /// 已自评
    var isAssessed: Bool { get }
    var isImmediateRedo: Bool { get }
    /// 作答方式的名称（学习、复习、AI 改编练习等）
    var modeLabel: String { get }
    func causeLines(_ pointTitle: (String) -> String) -> [String]
}

nonisolated extension SubjectiveAttemptRecord {
    var resultValue: PartResult? { overallResult }
    var parts: [PartResult] { partResults.compactMap(PartResult.init(rawValue:)) }

    var assessmentHistory: [SubjectiveAssessment] {
        get { assessmentHistoryData.flatMap { try? JSONDecoder().decode([SubjectiveAssessment].self, from: $0) } ?? [] }
        set { assessmentHistoryData = try? JSONEncoder().encode(newValue) }
    }

    var partCauses: [PartCause] {
        get { partCausesData.flatMap { try? JSONDecoder().decode([PartCause].self, from: $0) } ?? [] }
        set { partCausesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var pastedImages: [PastedImage] {
        get { pastedImagesData.flatMap { try? JSONDecoder().decode([PastedImage].self, from: $0) } ?? [] }
        set { pastedImagesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// 看答案前贴的图片（看答案后补贴的不算作答）
    var pastedBeforeReveal: [PastedImage] {
        pastedImages.filter { img in revealedAt.map { img.at < $0 } ?? true }
    }

    var gradings: [SavedGrading] {
        get { gradingHistoryData.flatMap { try? JSONDecoder().decode([SavedGrading].self, from: $0) } ?? [] }
        set { gradingHistoryData = try? JSONEncoder().encode(newValue) }
    }

    /// 某一问在这次作答中的结果
    func result(of label: String) -> PartResult? {
        partLabels.firstIndex(of: label).flatMap { $0 < partResults.count ? PartResult(rawValue: partResults[$0]) : nil }
    }

    /// 各问的自评结果，同 result(of:)
    var resultsByPart: [String: PartResult] {
        var map: [String: PartResult] = [:]
        for label in partLabels where map[label] == nil {
            if let r = result(of: label) { map[label] = r }
        }
        return map
    }
}

nonisolated extension SubjectiveAttempt: SubjectiveAttemptRecord {
    var confidenceValue: SubjectiveConfidence? {
        get { confidence.flatMap(SubjectiveConfidence.init(rawValue:)) }
        set { confidence = newValue?.rawValue }
    }

    var overallResult: PartResult? {
        get { result.flatMap(PartResult.init(rawValue:)) }
        set { result = newValue?.rawValue }
    }

    var isAssessed: Bool { assessedAt != nil }
    var modeLabel: String { AttemptMode.label(of: mode) }
}

/// 一次提交或修改的自评
nonisolated struct SubjectiveAssessment: Codable {
    var at: Date
    var parts: [String]
    var result: String
    var errorTypes: [String]
    var note: String?
    var partCauses: [PartCause]? = nil
}

/// 学习页（第一次做原题的地方）改编出的题：只保存题目，供之后查看；不记作答，不参与任何统计和复习安排
@Model
final class SavedVariant {
    var packID: String
    var sectionID: String
    var originalID: String
    /// choice | subjective
    var kind: String
    var createdAt: Date
    var stem: String
    /// 完整题目（JSON）。choice：Grader.snapshot；subjective：stem、answer、part_labels
    var content: Data?
    /// 改编用的模型
    var model: String?

    init(packID: String, sectionID: String, originalID: String, kind: String, stem: String, content: Data?,
         model: String?) {
        self.packID = packID
        self.sectionID = sectionID
        self.originalID = originalID
        self.kind = kind
        self.createdAt = .now
        self.stem = stem
        self.content = content
        self.model = model
    }
}

/// 复习用的 AI 改编题改编好、还没做完的，存下来：下次打开同一道原题的改编（AI 改编复习、复习页题目下方的「AI改编」）
/// 直接用这道，不重新改编。每道原题最多存一道；做完（选择题提交、主观题自评）、重新改编、评价出得不好后不再使用。
/// 学习页的改编练习不存这里（另存 SavedVariant）
@Model
final class PendingVariant {
    var packID: String
    var sectionID: String
    /// 原题 id
    var originalID: String
    /// 改编题 id（原题 id~ai-xxxx），作答记录（VariantAttempt.variantID）、评价（QuestionMark）都按它
    var variantID: String
    /// choice | subjective
    var kind: String
    var createdAt: Date
    /// choice：模型返回的题目 JSON；subjective：SubjectiveGenerated.content
    var content: Data
    /// 改编用的模型（LLMUsage，JSON）
    var usageData: Data?

    init(packID: String, sectionID: String, originalID: String, variantID: String, kind: String, content: Data,
         usageData: Data?) {
        self.packID = packID
        self.sectionID = sectionID
        self.originalID = originalID
        self.variantID = variantID
        self.kind = kind
        self.createdAt = .now
        self.content = content
        self.usageData = usageData
    }

    /// 存下改编好的题，替换这道原题以前存的
    static func save(packID: String, sectionID: String, originalID: String, variantID: String, kind: String,
                     content: Data, usageData: Data?, in context: ModelContext) {
        discard(packID: packID, originalID: originalID, in: context)
        context.insert(PendingVariant(packID: packID, sectionID: sectionID, originalID: originalID, variantID: variantID,
                                      kind: kind, content: content, usageData: usageData))
        try? context.save()
    }

    /// 这道原题存着、还能用的改编题：已经做完或评价出得不好的删掉
    static func usable(packID: String, originalID: String, kind: String, in context: ModelContext) -> PendingVariant? {
        let list = (try? context.fetch(FetchDescriptor<PendingVariant>(
            predicate: #Predicate { $0.packID == packID && $0.originalID == originalID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        var found: PendingVariant?
        for p in list {
            if found == nil, p.kind == kind, !p.isDone(in: context) { found = p } else { context.delete(p) }
        }
        try? context.save()
        return found
    }

    /// 不再用这道原题存着的改编题（重新改编时）
    static func discard(packID: String, originalID: String, in context: ModelContext) {
        ((try? context.fetch(FetchDescriptor<PendingVariant>(
            predicate: #Predicate { $0.packID == packID && $0.originalID == originalID }))) ?? []).forEach(context.delete)
        try? context.save()
    }

    /// 选择题提交过、主观题自评过（不算重做），或评价了出得不好
    private func isDone(in context: ModelContext) -> Bool {
        if QuestionMark.fetch(packID: packID, questionID: variantID, in: context)?.faulty == true { return true }
        let attempts = VariantAttempt.attempts(variantID: variantID, in: context)
        return kind == "choice" ? !attempts.isEmpty : attempts.contains { $0.isAssessed && !$0.isRedo }
    }

    var usage: LLMUsage? { usageData.flatMap { try? JSONDecoder().decode(LLMUsage.self, from: $0) } }
}

/// 「题目有错」的常见问题（QuestionMark.faultyReasons 存的是 rawValue）。前三项以外只用于 AI 改编题（评价「出得不好」）
nonisolated enum FaultReason: String, CaseIterable, Sendable {
    case wrongAnswer = "wrong_answer"
    case multipleAnswers = "multiple_answers"
    case unclear
    case outOfScope = "out_of_scope"
    case offTopic = "off_topic"
    case tooSimilar = "too_similar"
    case tooEasy = "too_easy"
    case tooHard = "too_hard"

    var label: String {
        switch self {
        case .wrongAnswer: "答案或解析错误"
        case .multipleAnswers: "答案不唯一"
        case .unclear: "题意不清"
        case .outOfScope: "超出原文范围"
        case .offTopic: "考的不是原题的知识点"
        case .tooSimilar: "和原题几乎一样"
        case .tooEasy: "太简单（如题干透露了答案）"
        case .tooHard: "太难或太繁琐"
        }
    }

    static func options(variant: Bool) -> [FaultReason] {
        variant ? allCases : [.wrongAnswer, .multipleAnswers, .unclear]
    }
}

/// AI 改编题的作答结果。题目由 AI 生成，不在教辅包里；结果按原题的规则计入原题的复习安排、订正状态和知识点掌握度，
/// 并交给下一次改编参考。标记「题目有问题」后都不计入。
/// 选择题提交时才记一条；主观题和原题一样，打开改编题就开始一次作答（笔迹、贴图、AI 批改和讲评都存在这里），
/// 自评前 result 为空字符串，不计入任何统计
@Model
final class VariantAttempt {
    var packID: String
    var sectionID: String
    /// 原题 id
    var originalID: String
    /// choice | subjective
    var kind: String
    var createdAt: Date
    /// 改编题题面和完整内容（JSON）。choice：Grader.snapshot；subjective：stem、answer、part_labels
    var stem: String
    var content: Data?
    /// choice：所选选项；subjective：nil
    var selection: String?
    /// choice：提交前每次改选后的作答
    var selectionHistory: [String] = []
    /// PartResult：choice 只有 correct / wrong；subjective 为整题结果，还没自评时为空字符串
    var result: String
    /// choice：sure | unsure | guess；subjective：SubjectiveConfidence，还没看答案时为空字符串
    var confidence: String
    var durationSeconds: Double
    /// 作答时距上次看到原题答案的秒数；原题没看过答案为 nil
    var sinceAnswerSeen: Double?
    /// choice：所选选项暴露的知识点；subjective：有小问没做对时为原题考查的知识点
    var weakPoints: [String] = []
    /// choice 自评的错误类型：第一项，全部见 errorTypes（可多选）。subjective：各问错误类型的合集
    var errorType: String?
    var errorTypes: [String] = []
    var errorNote: String?
    /// 选「两个概念混淆了」时指出的知识点（subjective 为各问的合集）
    var confusedPoints: [String] = []
    /// choice：每次提交或修改错因的记录（JSON 编码的 [CauseEntry]）
    var causeHistoryData: Data?
    /// subjective：小问编号、各问结果（PartResult）和没做对的各问的错因（JSON 编码的 [PartCause]）
    var partLabels: [String] = []
    var partResults: [String] = []
    var partCausesData: Data?
    /// subjective：每次提交或修改自评的记录（JSON 编码的 [SubjectiveAssessment]）
    var assessmentHistoryData: Data?
    var correctionNote: String?
    var correctionUpdatedAt: Date?
    var correctionHistoryData: Data?
    /// 订正笔记的手写：各书写区渲染成的 PNG（JSON 编码的 [Data]），和书写区数量
    var correctionInkData: Data?
    var correctionAreaCount: Int = 0
    /// 这道改编题的 AI 讲评和追问
    var reviewConversationData: Data?
    /// 早期版本在每次作答上标记「这道改编题有问题」；已迁移到 QuestionMark（按 variantID），不再读写
    var flaggedAt: Date?
    var flagReasons: [String] = []
    var flagNote: String?
    /// 这道改编题的 id（「原题 id~ai-xxxx」）：重做时沿用，找出这道改编题的以往作答；
    /// 「题目有错」按它记在 QuestionMark。早期记录启动时补上（RecordMaintenance.migrateVariantFaultsOnce）
    var variantID: String?

    // 以下只用于 subjective，含义同 SubjectiveAttempt 的同名字段；早期记录都是默认值
    /// 学习页的改编练习：保存作答，但不计入复习安排、订正状态、掌握度和统计
    var practice: Bool = false
    /// 重做这道改编题
    var isRedo: Bool = false
    var revealedAt: Date?
    var assessedAt: Date?
    var writingSeconds: Double = 0
    var feedbackSeconds: Double = 0
    var lastViewedAt: Date?
    var strokesBeforeReveal: Int = 0
    var strokesAfterReveal: Int = 0
    var typedAnswers: [String] = []
    var autoMatched: [String] = []
    var answerHidden: Bool = false
    /// 书写区数量
    var areaCount: Int = 0
    /// 这次作答的笔迹（PKDrawing 数据）：收起、重做、自评时从页面上取下存进来
    var inkData: Data?
    @Attribute(.externalStorage) var pastedImagesData: Data?
    var gradingHistoryData: Data?
    @Attribute(.externalStorage) var reviewImagesData: Data?
    var aiCompared: Bool = false
    var aiDisagreements: [String] = []

    init(packID: String, sectionID: String, originalID: String, kind: String, stem: String, content: Data?,
         selection: String?, result: String, confidence: String, durationSeconds: Double) {
        self.packID = packID
        self.sectionID = sectionID
        self.originalID = originalID
        self.kind = kind
        self.createdAt = .now
        self.stem = stem
        self.content = content
        self.selection = selection
        self.result = result
        self.confidence = confidence
        self.durationSeconds = durationSeconds
    }

    /// 原题的全部改编题结果（已自评的，含练习和题目有错的），按时间先后。交给下次改编参考
    static func all(packID: String, originalID: String, in context: ModelContext) -> [VariantAttempt] {
        ((try? context.fetch(FetchDescriptor<VariantAttempt>(
            predicate: #Predicate { $0.packID == packID && $0.originalID == originalID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []).filter(\.isAssessed)
    }

    /// 计入原题复习安排、订正状态的改编题结果：已自评、不是练习、改编题没标记有错
    static func counted(packID: String, originalID: String, in context: ModelContext) -> [VariantAttempt] {
        let faulty = QuestionMark.faulty(packID: packID, in: context)
        return all(packID: packID, originalID: originalID, in: context).filter { $0.counts(faulty: faulty) }
    }

    /// 同一道主观改编题的全部作答（含未自评的），按时间先后
    static func attempts(variantID: String, in context: ModelContext) -> [VariantAttempt] {
        (try? context.fetch(FetchDescriptor<VariantAttempt>(
            predicate: #Predicate { $0.variantID == variantID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// 开始一次主观改编题作答；content 为改编题的完整内容（JSON）
    static func startSubjective(packID: String, sectionID: String, originalID: String, variantID: String,
                                stem: String, content: Data?, practice: Bool, redo: Bool,
                                in context: ModelContext) -> VariantAttempt {
        let v = VariantAttempt(packID: packID, sectionID: sectionID, originalID: originalID, kind: "subjective",
                               stem: stem, content: content, selection: nil, result: "", confidence: "",
                               durationSeconds: 0)
        v.variantID = variantID
        v.practice = practice
        v.isRedo = redo
        context.insert(v)
        try? context.save()
        return v
    }

    /// 没看答案、没写没贴、没请 AI 批改就收起的作答：删掉，不留记录。返回是否删掉了
    @discardableResult
    static func discardIfEmpty(_ v: VariantAttempt, in context: ModelContext) -> Bool {
        guard v.revealedAt == nil, v.inkData == nil, v.pastedImagesData == nil, v.gradingHistoryData == nil else { return false }
        context.delete(v)
        try? context.save()
        return true
    }

    var resultValue: PartResult? { PartResult(rawValue: result) }
    var isAssessed: Bool { resultValue != nil }
    /// 计入原题的复习安排、订正状态、掌握度和统计：已自评、不是练习、这道改编题没标记有错。
    /// faulty 可以是本书的有错标记（QuestionMark.faulty）或其 id 集合
    func counts(faulty: [String: QuestionMark]) -> Bool { isAssessed && !practice && !isFaulty(faulty.keys) }
    func counts(faulty: Set<String>) -> Bool { isAssessed && !practice && !isFaulty(faulty) }

    /// 这道改编题标记了有错
    func isFaulty<S: Sequence>(_ faultyIDs: S) -> Bool where S.Element == String {
        guard let variantID else { return false }
        return faultyIDs.contains(variantID)
    }
    var isCorrect: Bool { resultValue == .correct }
    /// 有把握：选择题「确定」，主观题看答案前「有把握」
    var sure: Bool { ReviewEvidence.Confidence(stored: confidence) == .sure }
    var isImmediate: Bool { (sinceAnswerSeen ?? .infinity) < AttemptRecord.immediateRedoInterval }
    /// 作答时间：主观题按看答案的时间
    var answeredAt: Date { revealedAt ?? createdAt }

    var causeHistory: [CauseEntry] {
        get { causeHistoryData.flatMap { try? JSONDecoder().decode([CauseEntry].self, from: $0) } ?? [] }
        set { causeHistoryData = try? JSONEncoder().encode(newValue) }
    }

    /// 错因，一行一条：choice 一行；subjective 一问一行
    func causeLines(_ pointTitle: (String) -> String) -> [String] {
        if kind == "subjective" {
            return partCauses.map { $0.line(single: partLabels.count <= 1, pointTitle) }.filter { !$0.isEmpty }
        }
        let raws = errorTypes.isEmpty ? (errorType.map { [$0] } ?? []) : errorTypes
        let types = raws.compactMap(ErrorType.init(rawValue:)).map { t in
            t == .confused && !confusedPoints.isEmpty
                ? "\(t.label)（\(confusedPoints.map(pointTitle).joined(separator: " ↔ "))）" : t.label
        }.joined(separator: "、")
        let line = [types.isEmpty ? nil : types, errorNote].compactMap { $0 }.joined(separator: "：")
        return line.isEmpty ? [] : [line]
    }
}

nonisolated extension VariantAttempt: SubjectiveAttemptRecord {
    var confidenceValue: SubjectiveConfidence? {
        get { SubjectiveConfidence(rawValue: confidence) }
        set { confidence = newValue?.rawValue ?? "" }
    }

    var overallResult: PartResult? {
        get { resultValue }
        set { result = newValue?.rawValue ?? "" }
    }

    var isImmediateRedo: Bool { isImmediate }
    var modeLabel: String { practice ? AttemptMode.aiPractice.label : isRedo ? "重做改编题" : AttemptMode.aiReview.label }
}

@MainActor
enum SubjectiveRecords {
    /// 某道题的全部作答，按时间先后
    static func attempts(packID: String, questionID: String, in context: ModelContext) -> [SubjectiveAttempt] {
        (try? context.fetch(FetchDescriptor<SubjectiveAttempt>(
            predicate: #Predicate { $0.packID == packID && $0.questionID == questionID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// 学习页当前的作答：最近一次学习或重做；没有就新建（并迁移旧版本按题保存的看答案时间和 AI 批改）
    static func currentForStudy(pack: StudyPack, question q: SubjectiveQuestion, sectionID: String,
                                in context: ModelContext) -> SubjectiveAttempt {
        let all = attempts(packID: pack.id, questionID: q.id, in: context)
        if let last = all.last(where: { $0.mode != AttemptMode.review.rawValue }) { return last }
        let a = start(pack: pack, question: q, sectionID: sectionID, mode: AttemptMode.learn.rawValue, in: context)
        let key = "\(pack.id)|\(q.id)"
        if let legacy = try? context.fetch(FetchDescriptor<SubjectiveProgress>(predicate: #Predicate { $0.key == key })).first {
            a.revealedAt = legacy.answerRevealedAt
            a.gradingHistoryData = legacy.gradingHistoryData
            legacy.gradingHistoryData = nil
        }
        try? context.save()
        return a
    }

    /// 复习页当前的作答：继续未自评的复习作答；否则把复习页上的旧笔迹存进上一次复习作答，清空页面，开始新的一次
    static func currentForReview(pack: StudyPack, question q: SubjectiveQuestion, sectionID: String,
                                 draftKey: String, in context: ModelContext) -> SubjectiveAttempt {
        let reviews = attempts(packID: pack.id, questionID: q.id, in: context).filter { $0.mode == AttemptMode.review.rawValue }
        if let open = reviews.last, open.assessedAt == nil { return open }
        archivePage(draftKey, into: reviews.last, pack: pack, question: q, sectionID: sectionID, in: context)
        let a = start(pack: pack, question: q, sectionID: sectionID, mode: AttemptMode.review.rawValue, in: context)
        try? context.save()
        return a
    }

    /// 学习页「重做这道题」：当前笔迹存进上一次作答，清空页面，新建一次重做
    static func startRedo(pack: StudyPack, question q: SubjectiveQuestion, sectionID: String, previous: SubjectiveAttempt,
                          draftKey: String, in context: ModelContext) -> SubjectiveAttempt {
        archivePage(draftKey, into: previous, pack: pack, question: q, sectionID: sectionID, in: context)
        let a = start(pack: pack, question: q, sectionID: sectionID, mode: AttemptMode.redo.rawValue, in: context)
        try? context.save()
        return a
    }

    private static func start(pack: StudyPack, question q: SubjectiveQuestion, sectionID: String, mode: String,
                              in context: ModelContext) -> SubjectiveAttempt {
        let a = SubjectiveAttempt(packID: pack.id, sectionID: sectionID, questionID: q.id, mode: mode)
        a.questionSnapshot = snapshot(q)
        a.contentHash = a.questionSnapshot.map(hash)
        context.insert(a)
        return a
    }

    /// 页面笔迹存进作答记录，清空页面，书写区恢复为初始数量（没有，需要时手动添加）
    private static func archivePage(_ key: String, into attempt: SubjectiveAttempt?, pack: StudyPack,
                                    question q: SubjectiveQuestion, sectionID: String, in context: ModelContext) {
        NotificationCenter.default.post(name: .draftFlushRequested, object: key)
        if let ink = try? context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == key })).first {
            if let attempt, attempt.inkData == nil, !ink.data.isEmpty { attempt.inkData = ink.data }
            DraftStore.delete(key, reason: "subjective_new_attempt", in: context)
        }
        let initial = 0
        let progress = SubjectiveProgress.fetchOrCreate(packID: pack.id, sectionID: sectionID, questionID: q.id,
                                                        initialPages: initial, in: context)
        progress.pageCount = initial
        progress.updatedAt = .now
    }

    /// 页面上的笔迹（先让画布立即保存）
    static func pageDrawing(_ key: String, in context: ModelContext) -> PKDrawing? {
        NotificationCenter.default.post(name: .draftFlushRequested, object: key)
        guard let ink = try? context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == key })).first
        else { return nil }
        return try? PKDrawing(data: ink.data)
    }

    /// 页面上看答案前、后写下的笔画数（按每一笔的落笔时间）
    static func strokeCounts(_ key: String, revealedAt: Date, in context: ModelContext) -> (before: Int, after: Int) {
        let strokes = pageDrawing(key, in: context)?.strokes ?? []
        let after = strokes.filter { $0.path.creationDate >= revealedAt }.count
        return (strokes.count - after, after)
    }

    static func snapshot(_ q: SubjectiveQuestion) -> Data? {
        var dict: [String: Any] = [:]
        if let s = q.stem { dict["stem"] = s }
        if let a = q.answer { dict["answer"] = a }
        if let i = q.questionImage { dict["question_image"] = i }
        if let i = q.answerImages { dict["answer_images"] = i }
        if let f = q.format { dict["format"] = f }
        if let i = q.input { dict["input"] = i }
        if let t = q.tests { dict["tests"] = t }
        if let t = q.alsoTests { dict["also_tests"] = t }
        if let parts = q.parts {
            dict["parts"] = parts.map { p in
                var d: [String: Any] = ["label": p.label]
                if let a = p.answer { d["answer"] = a }
                if let t = p.tests { d["tests"] = t }
                if let t = p.alsoTests { d["also_tests"] = t }
                if let pts = p.points { d["points"] = pts }
                if let acc = p.accept { d["accept"] = acc }
                return d
            }
        }
        return try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// 题目内容的哈希（题面、答案、小问、得分点、图片和知识点），用来发现教辅包更新了题目
    static func contentHash(_ q: SubjectiveQuestion) -> String? {
        snapshot(q).map(hash)
    }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 最近一次看到这道题答案的时间
    static func answerLastSeen(packID: String, questionID: String, in context: ModelContext) -> Date? {
        attempts(packID: packID, questionID: questionID, in: context)
            .compactMap { a in a.revealedAt.map { max($0, a.lastViewedAt ?? $0) } }
            .max()
    }

    /// 最近一次自评（不算看答案后立即重做的）中做对的小问
    static func lastCorrectParts(packID: String, questionID: String, excluding current: AnyObject,
                                 in context: ModelContext) -> Set<String> {
        guard let last = attempts(packID: packID, questionID: questionID, in: context)
            .last(where: { $0 !== current && $0.assessedAt != nil && !$0.isImmediateRedo }) else { return [] }
        var labels = Set<String>()
        for (label, raw) in zip(last.partLabels, last.partResults) where raw == PartResult.correct.rawValue {
            labels.insert(label)
        }
        // 上次跳过的小问沿用更早的结论
        for (label, raw) in zip(last.partLabels, last.partResults) where raw == PartResult.skipped.rawValue {
            labels.insert(label)
        }
        return labels
    }
}
