import Foundation
import SwiftData

/// 作答方式（AttemptRecord.mode、SubjectiveAttempt.mode 存的是 rawValue）
nonisolated enum AttemptMode: String {
    case learn, review, redo
    /// AI 改编：题目是 AI 在原题上改编的变式题。作答记在 VariantAttempt，不写 AttemptRecord
    case aiReview = "ai_review"
    /// 学习页（第一次做原题的地方）的 AI 改编练习：选择题不记作答，题目另存为 SavedVariant；
    /// 主观题作答记在 VariantAttempt（practice），不计入复习安排和统计
    case aiPractice = "ai_practice"

    var isAI: Bool { self == .aiReview || self == .aiPractice }

    var label: String {
        switch self {
        case .learn: "学习"
        case .review: "复习"
        case .redo: "重做"
        case .aiReview: "AI 改编复习"
        case .aiPractice: "AI 改编练习"
        }
    }

    /// 记录里存的作答方式的名称；认不出的原样显示
    static func label(of raw: String) -> String { AttemptMode(rawValue: raw)?.label ?? raw }
}

/// 一次作答。只通过 id 引用教辅内容，教辅包重新导入不影响这里的记录。
@Model
final class AttemptRecord {
    var packID: String
    var sectionID: String
    var questionID: String
    /// learn（按轮学习）| review（间隔复习）| redo（错题重做）
    var mode: String
    var roundNum: Int
    var createdAt: Date
    /// 作答用时：只计 App 在前台、题目在屏幕上的时间（早期记录是从打开题目到提交的墙钟时间）
    var durationSeconds: Double
    var selection: String
    /// 提交前每次改选后的作答，按时间顺序
    var selectionHistory: [String]
    /// 与 selectionHistory 一一对应：每次选择时的作答用时（秒）；早期记录为空
    var selectionTimes: [Double] = []
    /// 复习时打乱了选项：按显示顺序排列的原题字母（显示字母按位置依次为 A、B…）；没打乱为空。
    /// selection 等仍是原题字母
    var optionOrder: [String] = []
    var isCorrect: Bool
    var blankResults: [Bool]
    /// sure（确定）| unsure（犹豫）| guess（蒙的）
    var confidence: String
    var hintShown: Bool
    /// 根据所选选项推算出的薄弱知识点（K- id），答对时为空
    var weakPoints: [String] = []
    /// 用户自评的错误类型（ErrorType.rawValue）：errorTypes 的第一项，旧记录只有这一项；未选为 nil
    var errorType: String?
    /// 用户自评的错误类型（可多选）。答错时是错误原因，答对但没把握时是没把握的原因；早期记录为空，见 causeTypes
    var errorTypes: [String] = []
    /// 用户自己写的错误原因（选「其他原因」时必填，其余可选）
    var errorNote: String?
    /// 自评「两个概念混淆了」时，学生指出混淆的知识点（K- id）
    var confusedPoints: [String] = []
    /// 每次提交或修改错误原因的记录（JSON 编码的 [CauseEntry]），按时间顺序；最后一条即当前的错误原因
    var causeHistoryData: Data?
    var contentHash: String
    /// 作答时的题目内容（JSON：判分内容加题型、解析），教辅包更新后仍能还原当时的题目
    var questionSnapshot: Data?
    /// 本次作答的 AI 讲评和追问；可选字段兼容已有数据库。
    var reviewConversationData: Data?
    /// 提交后停留在答案、解析、错因和讲评上的时间（只计前台、在屏幕上的时间），多次打开累加
    var feedbackSeconds: Double = 0
    /// AI 讲评之后学生追问的次数
    var followUpCount: Int = 0
    /// 最后一次在屏幕上看到这次作答的答案与解析的时间（离开题目或 App 退到后台时更新）
    var lastViewedAt: Date?
    /// 距上次看到这道题答案的秒数（以往作答的提交时间或之后再看的时间，取最近的）；第一次作答为 nil
    var sinceAnswerSeen: Double?
    /// 所在学习会话（作答间隔超过 StudySession.gap 即为新会话）及本次是会话中的第几题
    var sessionID: String?
    var sessionIndex: Int = 0
    /// 在手机复习 App 上作答、同步过来的：手机上这条结果的 id（防止重复导入，见 PhoneSyncImport）；iPad 上作答的为 nil
    var phoneID: String?
    /// 这次作答在书写区里写下的笔迹（PKDrawing 数据，书写区外的不存）；没有书写或早期记录为 nil
    @Attribute(.externalStorage) var inkData: Data?
    /// 提交前、提交后（看答案后补写）的笔画数
    var inkStrokesBefore: Int = 0
    var inkStrokesAfter: Int = 0
    /// 最后一次收集这次作答笔迹的时间；同一页之后落笔的笔画属于下一次作答
    var inkUpdatedAt: Date?
    /// 订正笔记：正确思路、下次要注意什么
    var correctionNote: String?
    var correctionUpdatedAt: Date?
    /// 订正笔记每次保存的内容（JSON 编码的 [CorrectionEntry]），按时间顺序；最后一条即当前的笔记
    var correctionHistoryData: Data?
    /// 订正笔记的手写：各书写区渲染成的 PNG（JSON 编码的 [Data]），和书写区数量
    var correctionInkData: Data?
    var correctionAreaCount: Int = 0

    init(packID: String, sectionID: String, questionID: String, mode: String, roundNum: Int,
         durationSeconds: Double, selection: String, selectionHistory: [String], selectionTimes: [Double],
         isCorrect: Bool, blankResults: [Bool], confidence: String, hintShown: Bool, weakPoints: [String],
         contentHash: String, questionSnapshot: Data?) {
        self.packID = packID
        self.sectionID = sectionID
        self.questionID = questionID
        self.mode = mode
        self.roundNum = roundNum
        self.createdAt = .now
        self.durationSeconds = durationSeconds
        self.selection = selection
        self.selectionHistory = selectionHistory
        self.selectionTimes = selectionTimes
        self.isCorrect = isCorrect
        self.blankResults = blankResults
        self.confidence = confidence
        self.hintShown = hintShown
        self.weakPoints = weakPoints
        self.contentHash = contentHash
        self.questionSnapshot = questionSnapshot
    }

    /// 看到答案后不久的重做（不到 immediateRedoInterval）：多半凭刚看过的答案，不算掌握的证据
    static let immediateRedoInterval = WrongBook.immediateRedoInterval

    var isImmediateRedo: Bool { (sinceAnswerSeen ?? .infinity) < Self.immediateRedoInterval }

    var causeHistory: [CauseEntry] {
        get { causeHistoryData.flatMap { try? JSONDecoder().decode([CauseEntry].self, from: $0) } ?? [] }
        set { causeHistoryData = try? JSONEncoder().encode(newValue) }
    }

    /// 自评的错误类型（或没把握的原因）；兼容只有 errorType 的旧记录
    var causeTypes: [ErrorType] {
        let raws = errorTypes.isEmpty ? (errorType.map { [$0] } ?? []) : errorTypes
        return raws.compactMap(ErrorType.init(rawValue:))
    }

    /// 「两个概念混淆了（A ↔ B）、粗心：原因」；没填为 nil
    func causeLine(_ pointTitle: (String) -> String) -> String? {
        let types = causeTypes.map { t in
            t == .confused && !confusedPoints.isEmpty
                ? "\(t.label)（\(confusedPoints.map(pointTitle).joined(separator: " ↔ "))）" : t.label
        }.joined(separator: "、")
        let line = [types.isEmpty ? nil : types, errorNote].compactMap { $0 }.joined(separator: "：")
        return line.isEmpty ? nil : line
    }

    /// 最近一次看到这道题答案的时间：以往每次作答提交时看到答案，之后打开作答也会再看到
    static func answerLastSeen(packID: String, questionID: String, in context: ModelContext) -> Date? {
        let all = (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.questionID == questionID }))) ?? []
        return all.map { max($0.createdAt, $0.lastViewedAt ?? $0.createdAt) }.max()
    }

    /// 这道题的全部作答，按时间先后
    static func all(packID: String, questionID: String, in context: ModelContext) -> [AttemptRecord] {
        (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.questionID == questionID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// 某个时间之后的全部作答，按时间先后（学习节奏提醒看最近答得怎么样）
    static func since(_ date: Date, in context: ModelContext) -> [AttemptRecord] {
        (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.createdAt > date },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// 某个时间之前、同一模式（packID 不为 nil 时还限同一本书）最近的若干条作答，用来算平时的错题率和用时
    static func latest(mode: AttemptMode, packID: String?, before date: Date, limit: Int,
                       in context: ModelContext) -> [AttemptRecord] {
        let raw = mode.rawValue
        var descriptor = FetchDescriptor<AttemptRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        if let packID {
            descriptor.predicate = #Predicate { $0.mode == raw && $0.packID == packID && $0.createdAt < date }
        } else {
            descriptor.predicate = #Predicate { $0.mode == raw && $0.createdAt < date }
        }
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}

/// 一次提交或修改的错误原因
nonisolated struct CauseEntry: Codable {
    var at: Date
    /// 第一个错误类型；全部类型见 types（早期记录为 nil）
    var type: String
    var note: String?
    var confusedPoints: [String]?
    var types: [String]? = nil
}

/// 订正笔记的一个版本；note 为 nil 表示清空了笔记
nonisolated struct CorrectionEntry: Codable {
    var at: Date
    var note: String?
}

/// 有订正笔记的作答记录：选择题、主观题和改编题
protocol CorrectionNoted: AnyObject {
    var createdAt: Date { get }
    var correctionNote: String? { get set }
    var correctionUpdatedAt: Date? { get set }
    var correctionHistoryData: Data? { get set }
    var correctionInkData: Data? { get set }
    var correctionAreaCount: Int { get set }
}

extension CorrectionNoted {
    /// 订正笔记的手写图片（PNG），按书写区顺序
    var correctionInk: [Data] {
        get { correctionInkData.flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? [] }
        set {
            correctionInkData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
            correctionUpdatedAt = .now
        }
    }

    var correctionHistory: [CorrectionEntry] {
        get { correctionHistoryData.flatMap { try? JSONDecoder().decode([CorrectionEntry].self, from: $0) } ?? [] }
        set { correctionHistoryData = try? JSONEncoder().encode(newValue) }
    }

    /// 保存订正笔记，并记下这一版
    func saveCorrection(_ note: String?) {
        // 有记录之前写的笔记先补成第一版
        if correctionHistoryData == nil, let old = correctionNote {
            correctionHistory = [CorrectionEntry(at: correctionUpdatedAt ?? createdAt, note: old)]
        }
        correctionNote = note
        correctionUpdatedAt = .now
        correctionHistory.append(CorrectionEntry(at: .now, note: note))
    }
}

extension AttemptRecord: CorrectionNoted {}
extension SubjectiveAttempt: CorrectionNoted {}
extension VariantAttempt: CorrectionNoted {}

/// 学习会话：相邻两次作答之间（扣除作答本身的用时）超过 gap 就算新的会话
enum StudySession {
    static let gap: TimeInterval = 30 * 60

    /// 本次作答所属的会话 id 和会话中的序号。workStarted：本题开始作答的大致时间
    /// 选择题、主观题的作答都算在内
    static func assign(workStarted: Date, in context: ModelContext) -> (id: String, index: Int) {
        var d = FetchDescriptor<AttemptRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 1
        var s = FetchDescriptor<SubjectiveAttempt>(predicate: #Predicate { $0.sessionID != nil },
                                                   sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        s.fetchLimit = 1
        var candidates: [(id: String, index: Int, active: Date)] = []
        if let a = try? context.fetch(d).first, let id = a.sessionID {
            candidates.append((id, a.sessionIndex, a.lastViewedAt ?? a.createdAt))
        }
        if let a = try? context.fetch(s).first, let id = a.sessionID {
            candidates.append((id, a.sessionIndex, a.lastViewedAt ?? a.revealedAt ?? a.createdAt))
        }
        if let last = candidates.max(by: { $0.active < $1.active }), workStarted.timeIntervalSince(last.active) < gap {
            return (last.id, last.index + 1)
        }
        return (UUID().uuidString, 1)
    }
}

/// 只累计 App 在前台、视图在屏幕上的时间
@MainActor
final class ActiveClock {
    private var accumulated: TimeInterval
    private var runningSince: Date?

    init(_ initial: TimeInterval = 0) { accumulated = initial }

    var elapsed: TimeInterval {
        accumulated + (runningSince.map { Date.now.timeIntervalSince($0) } ?? 0)
    }

    var isRunning: Bool { runningSince != nil }

    func setRunning(_ running: Bool) {
        if running, runningSince == nil {
            runningSince = .now
        } else if !running, let s = runningSince {
            accumulated += Date.now.timeIntervalSince(s)
            runningSince = nil
        }
    }

    func reset(to value: TimeInterval = 0) {
        accumulated = value
        if runningSince != nil { runningSince = .now }
    }
}

/// 复习队列中的一道题。记忆状态和到期时间由这道题的全部作答按 FSRS 重放算出（见 ReviewScheduler.refresh）
@Model
final class ReviewItem {
    @Attribute(.unique) var key: String
    var packID: String
    var questionID: String
    /// 旧版固定间隔的阶段数，已不再使用
    var stage: Int
    var dueAt: Date
    var updatedAt: Date
    /// FSRS 记忆状态：稳定性（天）、难度（1…10）、最近一次计入的作答时间、计入次数、遗忘次数
    var stability: Double = 0
    var difficulty: Double = 0
    var lastReviewAt: Date?
    var reps: Int = 0
    var lapses: Int = 0
    /// 最近一次计入的评分（FSRSRating.rawValue）
    var lastRating: Int = 0
    /// 以往复习这道题的用时中位数（秒，作答加看答案、解析）；没复习过为 nil。用来安排每天的量、调整目标记住率
    var reviewSeconds: Double?

    init(packID: String, questionID: String, dueAt: Date) {
        self.key = "\(packID)|\(questionID)"
        self.packID = packID
        self.questionID = questionID
        self.stage = 0
        self.dueAt = dueAt
        self.updatedAt = .now
    }

    /// 现在还记得的概率
    var retrievability: Double? {
        guard let last = lastReviewAt, stability > 0 else { return nil }
        return FSRS.retrievability(elapsedDays: Double(FSRS.elapsedDays(from: last, to: .now)), stability: stability)
    }
}

/// 一道题的书写状态（主观题；选择题添加书写区后也会有）。笔迹本身存在 DraftInk（键 DraftKey.question），详细记录在 SubjectiveWork 目录
@Model
final class SubjectiveProgress {
    @Attribute(.unique) var key: String
    var packID: String
    var sectionID: String
    var questionID: String
    /// 书写区数量（每块一页高）
    var pageCount: Int
    /// 第一次展开答案的时间；nil 表示还没看答案
    var answerRevealedAt: Date?
    /// 按时间排列的 AI 批改结果（JSON 编码的 [SavedGrading]）。
    var gradingHistoryData: Data?
    var updatedAt: Date

    init(packID: String, sectionID: String, questionID: String, initialPages: Int = 1) {
        self.key = "\(packID)|\(questionID)"
        self.packID = packID
        self.sectionID = sectionID
        self.questionID = questionID
        self.pageCount = initialPages
        self.updatedAt = .now
    }

    /// initialPages：新建时的书写区数量（主观题、选择题都是 0）
    static func fetchOrCreate(packID: String, sectionID: String, questionID: String, initialPages: Int = 1,
                              in context: ModelContext) -> SubjectiveProgress {
        let key = "\(packID)|\(questionID)"
        if let hit = try? context.fetch(FetchDescriptor<SubjectiveProgress>(predicate: #Predicate { $0.key == key })).first {
            return hit
        }
        let p = SubjectiveProgress(packID: packID, sectionID: sectionID, questionID: questionID,
                                   initialPages: initialPages)
        context.insert(p)
        return p
    }
}

/// 每节的学习进度
@Model
final class SectionProgress {
    @Attribute(.unique) var key: String
    var packID: String
    var sectionID: String
    /// 当前轮在 rounds 中的下标
    var roundIndex: Int
    /// lecture | questions | done
    var phase: String
    var questionIndex: Int
    var completed: Bool
    var updatedAt: Date

    init(packID: String, sectionID: String) {
        self.key = "\(packID)|\(sectionID)"
        self.packID = packID
        self.sectionID = sectionID
        self.roundIndex = 0
        self.phase = "lecture"
        self.questionIndex = 0
        self.completed = false
        self.updatedAt = .now
    }
}

/// AI 讲解缓存，避免每次打开都重新生成
@Model
final class LectureCache {
    @Attribute(.unique) var key: String
    var text: String
    var model: String
    var createdAt: Date
    /// 生成时的提示词版本（Prompts.lectureVersion），用于提示旧讲解可以重新生成
    var promptVersion: Int = 1
    var usageData: Data?

    var usage: LLMUsage? {
        get { usageData.flatMap { try? JSONDecoder().decode(LLMUsage.self, from: $0) } }
        set { usageData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    init(key: String, text: String, model: String, promptVersion: Int = 1, usage: LLMUsage? = nil) {
        self.key = key
        self.text = text
        self.model = model
        self.createdAt = .now
        self.promptVersion = promptVersion
        self.usage = usage
    }

    /// 已不再使用整节比喻：删掉以前生成的比喻缓存（键以 |metaphor 结尾）
    static func purgeMetaphors(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<LectureCache>(predicate: #Predicate { $0.key.contains("|metaphor") }))) ?? []
        guard !all.isEmpty else { return }
        all.filter { $0.key.hasSuffix("|metaphor") }.forEach(context.delete)
        try? context.save()
    }

    static func text(for key: String, in context: ModelContext) -> String? {
        try? context.fetch(FetchDescriptor<LectureCache>(predicate: #Predicate { $0.key == key })).first?.text
    }
}

enum RecordMaintenance {
    /// 错因改为「知识点 + 错误类型」之前的作答都是测试数据：升级后首次启动时清空一次
    /// 作答记录、复习队列和学习进度（AI 讲解缓存与草稿保留）
    static func purgeLegacyRecordsOnce(in context: ModelContext) {
        let key = "records.purgedBeforeKnowledgePoints"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try context.delete(model: AttemptRecord.self)
            try context.delete(model: ReviewItem.self)
            try context.delete(model: SectionProgress.self)
            try context.save()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            print("清空旧作答记录失败：\(error)")
        }
    }

    /// AI 改编题的作答不写 AttemptRecord（结果另记 VariantAttempt）；删掉早期版本留下的变式题作答、书写区数量和笔迹
    static func purgeAIVariantRecords(in context: ModelContext) {
        do {
            let mode = AttemptMode.aiReview.rawValue
            let attempts = try context.fetch(FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.mode == mode }))
            let progress = try context.fetch(FetchDescriptor<SubjectiveProgress>(
                predicate: #Predicate { $0.questionID.contains("~ai-") }))
            let inks = try context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key.contains("~ai-") }))
            guard !(attempts.isEmpty && progress.isEmpty && inks.isEmpty) else { return }
            attempts.forEach(context.delete)
            progress.forEach(context.delete)
            inks.forEach(context.delete)
            try context.save()
        } catch {
            print("清除 AI 改编记录失败：\(error)")
        }
    }

    /// 改编题的「题目有错」改为按改编题 id 记在 QuestionMark，和原题同一套：
    /// 早期的改编题作答补上 variantID（选择题从题目内容里取，取不到就各算一道），每次作答上的标记搬过去。只做一次
    static func migrateVariantFaultsOnce(in context: ModelContext) {
        let key = "migratedVariantFaults"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            let legacy = try context.fetch(FetchDescriptor<VariantAttempt>(predicate: #Predicate { $0.variantID == nil }))
            for v in legacy {
                let stored = v.content.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["id"] as? String
                v.variantID = stored ?? "\(v.originalID)~ai-\(UUID().uuidString.prefix(8).lowercased())"
            }
            let flagged = try context.fetch(FetchDescriptor<VariantAttempt>(predicate: #Predicate { $0.flaggedAt != nil }))
            for v in flagged {
                guard let id = v.variantID else { continue }
                let mark = QuestionMark.fetch(packID: v.packID, questionID: id, in: context) ?? {
                    let m = QuestionMark(packID: v.packID, questionID: id)
                    context.insert(m)
                    return m
                }()
                mark.faultyAt = mark.faultyAt ?? v.flaggedAt
                mark.faultyNote = mark.faultyNote ?? v.flagNote
                if mark.faultyReasons.isEmpty { mark.faultyReasons = v.flagReasons }
                mark.updatedAt = .now
                v.flaggedAt = nil
                v.flagReasons = []
                v.flagNote = nil
            }
            try context.save()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            print("迁移改编题有错标记失败：\(error)")
        }
    }

    struct Summary {
        var attempts = 0
        var reviews = 0
        var progress = 0
        var subjective = 0
    }

    /// 清除某节的作答记录、复习队列和学习进度。AI 讲解缓存保留（重新生成要花费调用）。
    @discardableResult
    static func clearSection(packID: String, sectionID: String, questionIDs: [String],
                             subjectiveIDs: [String] = [], in context: ModelContext) throws -> Summary {
        var summary = Summary()

        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID }))
        attempts.forEach(context.delete)
        summary.attempts = attempts.count

        let ids = Set(questionIDs)
        let reviews = try context.fetch(FetchDescriptor<ReviewItem>(predicate: #Predicate { $0.packID == packID }))
            .filter { ids.contains($0.questionID) }
        reviews.forEach(context.delete)
        summary.reviews = reviews.count

        // 主观题：书写状态、页面笔迹和详细记录一起清掉
        let subjective = try context.fetch(FetchDescriptor<SubjectiveProgress>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID }))
        subjective.forEach(context.delete)
        // 主观题复习页的笔迹属于复习作答，一起清掉
        for q in subjectiveIDs {
            for draftKey in [DraftKey.question(pack: packID, questionID: q), DraftKey.review(pack: packID, questionID: q)] {
                try context.fetch(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == draftKey }))
                    .forEach(context.delete)
            }
        }
        // 详细笔迹记录：主观题和选择题书写区都清掉（选择题的草稿笔迹本身保留）
        SubjectiveInkLog.delete(packID: packID, questionIDs: subjectiveIDs + questionIDs)
        try context.fetch(FetchDescriptor<SubjectiveAttempt>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID })).forEach(context.delete)
        let variants = try context.fetch(FetchDescriptor<VariantAttempt>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID }))
        variants.forEach(context.delete)
        try context.fetch(FetchDescriptor<SavedVariant>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID })).forEach(context.delete)
        try context.fetch(FetchDescriptor<PendingVariant>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID })).forEach(context.delete)
        // 改编题的有错标记也清掉
        let marked = Set(questionIDs + subjectiveIDs + variants.compactMap(\.variantID))
        try context.fetch(FetchDescriptor<QuestionMark>(predicate: #Predicate { $0.packID == packID }))
            .filter { marked.contains($0.questionID) }.forEach(context.delete)
        summary.subjective = subjectiveIDs.count

        let key = "\(packID)|\(sectionID)"
        let progress = try context.fetch(FetchDescriptor<SectionProgress>(predicate: #Predicate { $0.key == key }))
        progress.forEach(context.delete)
        summary.progress = progress.count
        PendingAnswers.removeChoices(pack: packID, questionIDs: questionIDs)

        try context.save()
        return summary
    }
}

/// 一页的草稿笔迹（PencilKit 的 PKDrawing 序列化数据）
@Model
final class DraftInk {
    @Attribute(.unique) var key: String
    var data: Data
    var strokeCount: Int
    /// 保存时画布宽度，排查横竖屏导致的错位时有用
    var contentWidth: Double
    /// 保存时书写区锚点（题目下方书写部分的顶边）的页面纵坐标；锚点以下的笔迹随它移动
    var areaTop: Double?
    /// 删除书写区时一并移走的笔迹（PKDrawing 数据，按删除先后累积），只存档，不显示
    var archivedData: Data?
    var updatedAt: Date

    init(key: String, data: Data, strokeCount: Int, contentWidth: Double) {
        self.key = key
        self.data = data
        self.strokeCount = strokeCount
        self.contentWidth = contentWidth
        self.updatedAt = .now
    }
}
