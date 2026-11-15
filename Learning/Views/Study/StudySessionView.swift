import QuartzCore
import SwiftData
import SwiftUI

/// 按 rounds 逐轮学习一节：讲授 → 做题 → 下一轮。阅读轮在题目后面接着做读后练习。进度自动保存。
/// 做过的题再次进入时展示第一次学习时的作答（不会被覆盖），之后的重做、复习作答列在下方的重做记录里。
struct StudySessionView: View {
    let pack: StudyPack
    let section: SectionFile
    /// 打开时定位到的位置（从分析页跳转来）；nil 时接着上次的进度
    var start: StudyPosition? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 本节的作答（选择题按时间倒序，主观题按时间先后）。不用 @Query：@Query 在数据库每次保存（切换讲解、草稿自动保存）后
    /// 都会重新取全部作答，切换和书写时会卡。这里只在作答有增删时重新取本节的；已有作答的字段变化照常刷新界面
    @State private var allAttempts: [AttemptRecord] = []
    @State private var subjectiveAttempts: [SubjectiveAttempt] = []
    @Query private var summaryAttempts: [PassageSummaryAttempt]
    @Query private var translationAttempts: [BackTranslationAttempt]
    @State private var progress: SectionProgress?
    @State private var bottomScrollRequest = 0
    @State private var resetZoomRequest = 0
    @State private var startApplied = false
    /// 各题下方展开的 AI 改编；值变化即重新改编。只在内存里，离开页面即消失
    @State private var aiVariants: [String: UUID] = [:]
    /// 这道题的 AI 改编改用备用模型
    @State private var aiVariantBackup: [String: Bool] = [:]
    /// 草稿模式下 Pencil 可以点的控件区域
    @State private var tapTargets = DraftTapTargets()
    /// 草稿模式：默认开启，Pencil 可在页面任何地方写，只允许双指滚动
    @AppStorage("draft.enabled") private var draftEnabled = true

    private var rounds: [Round] { section.rounds }

    /// 本节每道题第一次学习时的作答（学习页显示它，之后的重做不会覆盖）
    private var latest: [String: AttemptRecord] {
        let ids = Set(section.questions.map(\.id))
        var map: [String: AttemptRecord] = [:]
        // allAttempts 按时间倒序，倒过来取最早的一次
        for a in allAttempts.reversed() where a.packID == pack.id && a.mode == AttemptMode.learn.rawValue
            && ids.contains(a.questionID) && map[a.questionID] == nil {
            map[a.questionID] = a
        }
        return map
    }

    /// 本节主观题在学习页（学习、重做）最近一次看过答案的作答
    private var latestSubjective: [String: SubjectiveAttempt] {
        var map: [String: SubjectiveAttempt] = [:]
        for a in subjectiveAttempts where a.packID == pack.id && a.mode != AttemptMode.review.rawValue && a.revealedAt != nil {
            map[a.questionID] = a
        }
        return map
    }

    /// 本节已展开过答案的主观题
    private var revealedSubjective: Set<String> { Set(latestSubjective.keys) }

    /// 一道题是否已做：选择题有第一次学习作答，主观题展开过答案（revealed 为 revealedSubjective，由调用方算好一次），读后练习提交过
    private func isDone(_ qid: String, _ latest: [String: AttemptRecord], _ revealed: Set<String>) -> Bool {
        if let item = ReadingPracticeItem(id: qid, in: pack) { return practiceDone(item) }
        return latest[qid] != nil || revealed.contains(qid)
    }

    private func practiceDone(_ item: ReadingPracticeItem) -> Bool {
        switch item {
        case .summary(let passage):
            return summaryAttempts.contains { $0.packID == pack.id && $0.passageID == passage.id }
        case .backTranslation(let passage, _, let drill):
            let key = BackTranslationAttempt.key(packID: pack.id, passageID: passage.id, english: drill.en)
            return translationAttempts.contains { $0.sentenceKey == key }
        }
    }

    /// 题号标签：选择题「第 N 题」，主观题「综合题 N」「填空题 N」，读后练习「段落概括」「回译 N」
    private func questionLabel(_ qid: String) -> String {
        if let q = pack.questions[qid] { return "第 \(q.num) 题" }
        if let q = pack.subjective[qid] { return "\(q.kindLabel) \(q.num)" }
        if let item = ReadingPracticeItem(id: qid, in: pack) { return item.label }
        return qid
    }

    /// 本轮按顺序做的条目：题目，阅读轮再加读后练习
    private func items(_ round: Round) -> [String] { round.items(in: pack) }

    /// 当前条目的 id
    private func currentItem(_ p: SectionProgress) -> String? {
        guard !rounds.isEmpty else { return nil }
        let list = items(rounds[min(p.roundIndex, rounds.count - 1)])
        return list.isEmpty ? nil : list[min(p.questionIndex, list.count - 1)]
    }

    /// 当前页面：阅读轮、习题轮没有讲解，停在讲解时按做题显示
    private func phase(_ p: SectionProgress) -> String {
        guard !rounds.isEmpty else { return p.phase }
        let round = rounds[min(p.roundIndex, rounds.count - 1)]
        // 没有题的轮只讲不练，一直停在讲解页
        if items(round).isEmpty { return "lecture" }
        guard p.phase == "lecture" else { return p.phase }
        return round.skipsLecture(in: pack) ? "questions" : p.phase
    }

    /// 当前题目所依据的阅读文章：有就上下分栏显示。段落概括也显示文章；回译不显示，免得直接看到原句
    private var currentPassage: Chunk? {
        guard let p = progress, phase(p) == "questions", let qid = currentItem(p) else { return nil }
        if case .summary(let passage) = ReadingPracticeItem(id: qid, in: pack) { return passage }
        return pack.questions[qid]?.passage.flatMap { pack.chunks[$0] }
    }

    /// 做题页（主观题、选择题）的草稿画布都挂详细笔迹记录
    private var subjectiveRecord: SubjectiveRecordContext? {
        guard let p = progress, phase(p) == "questions", let qid = currentItem(p) else { return nil }
        guard pack.subjective[qid] != nil || pack.questions[qid] != nil else { return nil }
        return SubjectiveRecordContext(packID: pack.id, sectionID: section.section.id, questionID: qid)
    }

    /// 某道题除第一次学习作答之外的所有作答（学习页重做、复习、错题重做），按时间先后
    private func redoRecords(_ questionID: String, excluding first: AttemptRecord?) -> [AttemptRecord] {
        allAttempts.reversed().filter {
            $0.packID == pack.id && $0.questionID == questionID && $0.persistentModelID != first?.persistentModelID
        }
    }

    var body: some View {
        Group {
            if let passage = currentPassage, let p = progress {
                let round = rounds[min(p.roundIndex, rounds.count - 1)]
                let count = items(round).count
                ReadingSplitView(pack: pack, passage: passage,
                                 status: "第 \(min(p.questionIndex, count - 1) + 1) / \(count) 题") {
                    page
                }
            } else {
                page
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(section.section.id) \(section.section.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear {
            loadAttempts()
            loadProgress()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
            if note.insertsOrDeletes([AttemptRecord.self, SubjectiveAttempt.self]) { loadAttempts() }
        }
    }

    private func loadAttempts() {
        let packID = pack.id, sectionID = section.section.id
        allAttempts = (try? context.fetch(FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        subjectiveAttempts = (try? context.fetch(FetchDescriptor<SubjectiveAttempt>(
            predicate: #Predicate { $0.packID == packID && $0.sectionID == sectionID },
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// 整页：可缩放滚动，草稿画布盖在上面
    private var page: some View {
        ZoomablePageScrollView(draftEnabled: draftEnabled, resetScrollID: progress?.updatedAt,
                               bottomRequest: bottomScrollRequest, resetZoomRequest: resetZoomRequest) {
            VStack(alignment: .leading, spacing: 20) {
                if let progress {
                    content(progress)
                } else {
                    ProgressView()
                }
                // 页面底部留一段空白草稿纸
                if draftEnabled { Color.clear.frame(height: 360) }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            // 与草稿画布同一坐标空间：主观题书写区的位置按它记录
            .coordinateSpace(.named(draftPageSpace))
            .environment(\.draftTapTargets, tapTargets)
            // 草稿画布盖住整页（含两侧边距），随内容一起滚动
            .overlay {
                if let key = draftKey {
                    DraftCanvas(key: key, enabled: draftEnabled, record: subjectiveRecord, tapTargets: tapTargets).id(key)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ p: SectionProgress) -> some View {
        let round = rounds[min(p.roundIndex, rounds.count - 1)]
        let latest = latest
        roundHeader(p, round)
        switch phase(p) {
        case "questions":
            let list = items(round)
            let index = min(p.questionIndex, list.count - 1)
            questionNavigator(p, round, latest)
            let isLast = index >= list.count - 1
            let nextLabel = !isLast ? "下一题" : p.roundIndex >= rounds.count - 1 ? "完成本节" : "进入下一轮"
            if let item = ReadingPracticeItem(id: list[index], in: pack) {
                ReadingPracticeCard(pack: pack, item: item, itemID: list[index], sectionID: section.section.id,
                                    nextLabel: nextLabel) {
                    advanceQuestion(p, round)
                }
                .id("\(round.num)-\(list[index])")
            } else if let q = pack.subjective[list[index]] {
                DetachableSubjectiveCard(pack: pack, question: q, sectionID: section.section.id,
                                         nextLabel: nextLabel) {
                    advanceQuestion(p, round)
                }
                .id("\(round.num)-\(q.id)")
            } else if let q = pack.questions[list[index]] {
                // 英语阅读题（带文章）不放进单独窗口
                if q.passage == nil {
                    DetachableQuestionCard(pack: pack, question: q, mode: .learn, roundNum: round.num,
                                           existing: latest[q.id], redoRecords: redoRecords(q.id, excluding: latest[q.id]),
                                           onAIVariant: { aiVariantBackup[q.id] = false; aiVariants[q.id] = UUID() },
                                           writing: WritingSpec(sectionID: section.section.id),
                                           nextLabel: nextLabel) {
                        advanceQuestion(p, round)
                    }
                    .id("\(round.num)-\(q.id)")
                } else {
                    QuestionCard(pack: pack, question: q, mode: .learn, roundNum: round.num,
                                 existing: latest[q.id], redoRecords: redoRecords(q.id, excluding: latest[q.id]),
                                 onAIVariant: { aiVariantBackup[q.id] = false; aiVariants[q.id] = UUID() },
                                 writing: WritingSpec(sectionID: section.section.id),
                                 nextLabel: nextLabel) {
                        advanceQuestion(p, round)
                    }
                    .id("\(round.num)-\(q.id)")
                }
                // 点题目卡片底部「AI改编」后在这里展开：只做练习，题目另存，作答、笔迹都不记
                if let token = aiVariants[q.id] {
                    InlineAIVariant(pack: pack, original: q,
                                    draftKey: DraftKey.question(pack: pack.id, questionID: q.id),
                                    useBackup: aiVariantBackup[q.id] ?? false,
                                    onRegenerate: {
                                        aiVariantBackup[q.id] = $0
                                        aiVariants[q.id] = UUID()
                                    },
                                    onClose: { aiVariants[q.id] = nil })
                        .id(token)
                }
                if latest[q.id] != nil { SavedVariantsCard(pack: pack, originalID: q.id) }
            }
        default:
            let revealed = revealedSubjective
            let answered = items(round).filter { isDone($0, latest, revealed) }.count
            let total = items(round).count
            DetachableLecture(
                pack: pack, section: section, round: round,
                startLabel: total == 0
                    ? (p.roundIndex >= rounds.count - 1 ? "完成本节" : "进入下一轮")
                    : answered == 0
                    ? "开始做题（\(total) 题）"
                    : "查看本轮题目（已做 \(answered) / \(total)）"
            ) {
                // 没有题的轮讲完直接往下走；有题时回到离开做题页时的那道题
                if total == 0 { advanceQuestion(p, round) } else { update(p) { $0.phase = "questions" } }
            }
            .id(round.num)
        }
    }

    private func roundHeader(_ p: SectionProgress, _ round: Round) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("第 \(p.roundIndex + 1) / \(rounds.count) 轮").font(.headline)
                if phase(p) == "questions" {
                    Text("· 第 \(p.questionIndex + 1) / \(items(round).count) 题").foregroundStyle(.secondary)
                }
                Spacer()
                // 阅读轮、习题轮没有讲解，没有题的轮只有讲解，都不用切换
                if !round.skipsLecture(in: pack) && !items(round).isEmpty { pageSwitcher(p, round) }
            }
            // 当前这一轮算作进行中：第 1 轮就有进度，最后一轮是满的
            ProgressView(value: Double(p.completed ? rounds.count : min(p.roundIndex + 1, rounds.count)),
                         total: Double(rounds.count))
        }
    }

    /// 在本轮的 AI 讲解和答题之间切换
    private func pageSwitcher(_ p: SectionProgress, _ round: Round) -> some View {
        let onLecture = p.phase == "lecture"
        return CapsuleSwitcher(items: [
            .init(title: "讲解", systemImage: "sparkles", selected: onLecture) {
                update(p) { $0.phase = "lecture" }
            },
            .init(title: "做题", systemImage: "pencil.and.list.clipboard", selected: !onLecture) {
                // 回到离开做题页时的那道题（questionIndex 切到讲解时不变）
                update(p) { $0.phase = "questions" }
            },
        ])
    }


    /// 题目状态图标：选择题按对错；主观题按自评结果，看过答案还没自评为蓝色；读后练习提交过为蓝色
    private func status(_ qid: String, _ latest: [String: AttemptRecord]) -> (String, Color) {
        if let item = ReadingPracticeItem(id: qid, in: pack) {
            return practiceDone(item) ? ("pencil.circle.fill", .blue) : ("pencil.circle", .secondary)
        }
        if pack.subjective[qid] != nil {
            guard let a = latestSubjective[qid] else { return ("pencil.circle", .secondary) }
            guard let r = a.resultValue else { return ("pencil.circle.fill", .blue) }
            return (SubjectiveCard.icon(r), SubjectiveCard.color(r))
        }
        guard let a = latest[qid] else { return ("circle", .secondary) }
        return a.isCorrect ? ("checkmark.circle.fill", .green) : ("xmark.circle.fill", .red)
    }

    /// 本轮各题的作答状态，点击切换；放不下时换行
    private func questionNavigator(_ p: SectionProgress, _ round: Round, _ latest: [String: AttemptRecord]) -> some View {
        FlowLayout(spacing: 10) {
            ForEach(Array(items(round).enumerated()), id: \.offset) { i, qid in
                let (icon, color) = status(qid, latest)
                let current = i == p.questionIndex
                Button {
                    update(p) { $0.questionIndex = i }
                } label: {
                    Label(questionLabel(qid), systemImage: icon)
                        .font(.callout)
                        .foregroundStyle(color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(current ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(current ? Color.accentColor : Color.secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .draftTappable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button(draftEnabled ? "关闭草稿模式" : "开启草稿模式",
                       systemImage: draftEnabled ? "pencil.slash" : "pencil.tip") { draftEnabled.toggle() }
                Button("恢复原大小", systemImage: "arrow.down.right.and.arrow.up.left") { resetZoomRequest += 1 }
                if let key = draftKey {
                    Button("清除本页草稿", systemImage: "trash", role: .destructive) {
                        DraftStore.delete(key, reason: "user_clear", in: context)
                    }
                }
            } label: {
                Label("草稿", systemImage: draftEnabled ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
            } primaryAction: {
                draftEnabled.toggle()
            }
            StateCheckMenu()
            Menu("跳到某一轮", systemImage: "list.number") {
                let latest = latest
                let revealed = revealedSubjective
                ForEach(Array(rounds.enumerated()), id: \.offset) { i, r in
                    let total = items(r).count
                    let answered = items(r).filter { isDone($0, latest, revealed) }.count
                    // 没有题的轮学过去就算完成（同 SectionCompletion.completedRounds）
                    let done = total == 0 ? (progress.map { $0.completed || $0.roundIndex > i } ?? false) : answered == total
                    Button {
                        guard let p = progress else { return }
                        update(p) {
                            $0.roundIndex = i
                            $0.phase = "lecture"
                            $0.questionIndex = 0
                            $0.completed = false
                        }
                    } label: {
                        Label(roundTitle(r, index: i) + (answered > 0 ? "（已做 \(answered)/\(total)）" : ""),
                              systemImage: done ? "checkmark.circle.fill"
                                : answered > 0 ? "circle.lefthalf.filled" : "circle")
                    }
                }
            }
        }
    }

    /// 当前页面的草稿键：讲解页按轮、做题页按题（读后练习按条目）
    private var draftKey: String? {
        guard let p = progress, !rounds.isEmpty else { return nil }
        let round = rounds[min(p.roundIndex, rounds.count - 1)]
        let sid = section.section.id
        switch phase(p) {
        case "questions":
            return currentItem(p).map { DraftKey.question(pack: pack.id, questionID: $0) }
        default:
            return DraftKey.lecture(pack: pack.id, section: sid, round: round.num)
        }
    }

    private func roundTitle(_ r: Round, index i: Int) -> String {
        let topic = r.displayTitle(chunkTitles: r.chunks.compactMap { pack.chunks[$0]?.title })
        return "第 \(i + 1) 轮 · \(topic)"
    }

    // MARK: - 进度

    private func loadProgress() {
        let key = "\(pack.id)|\(section.section.id)"
        if let p = try? context.fetch(FetchDescriptor<SectionProgress>(predicate: #Predicate { $0.key == key })).first {
            if p.roundIndex >= rounds.count { p.roundIndex = max(rounds.count - 1, 0) }
            // 以前停在本轮小结页（或更早的「本节学完了」页），现在停在本轮最后一题
            if p.phase == "roundDone" || p.phase == "done" {
                p.phase = "questions"
                p.questionIndex = max(items(rounds[p.roundIndex]).count - 1, 0)
            }
            applyStart(p)
            applyDebugArguments(p)
            progress = p
        } else {
            let p = SectionProgress(packID: pack.id, sectionID: section.section.id)
            context.insert(p)
            applyStart(p)
            applyDebugArguments(p)
            try? context.save()
            progress = p
        }
    }

    /// 跳转到指定位置，只在第一次出现时生效；不改动「已学完」标记
    private func applyStart(_ p: SectionProgress) {
        guard let start, !startApplied, !rounds.isEmpty else { return }
        startApplied = true
        let round = min(max(start.roundIndex, 0), rounds.count - 1)
        p.roundIndex = round
        switch start.page {
        case .lecture:
            p.phase = "lecture"
            p.questionIndex = 0
        case .question(let index):
            p.phase = "questions"
            p.questionIndex = min(max(index, 0), max(items(rounds[round]).count - 1, 0))
        }
        p.updatedAt = .now
        try? context.save()
    }

    /// 调试：启动参数 -debugRound 9 -debugPhase questions -debugQuestion 1 直接定位到某轮某题
    private func applyDebugArguments(_ p: SectionProgress) {
        #if DEBUG
        let d = UserDefaults.standard
        guard d.object(forKey: "debugRound") != nil else { return }
        p.roundIndex = min(max(d.integer(forKey: "debugRound") - 1, 0), rounds.count - 1)
        p.phase = d.string(forKey: "debugPhase") ?? "lecture"
        p.questionIndex = d.integer(forKey: "debugQuestion")
        p.completed = false
        if d.bool(forKey: "debugScrollBottom") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                bottomScrollRequest += 1
            }
        }
        // 调试：-debugCycleRounds YES 自动轮流切换各轮，并打印每次切换后的最长卡顿帧
        if d.bool(forKey: "debugCycleRounds") {
            let monitor = FrameMonitor()
            Task {
                try? await Task.sleep(for: .seconds(3))
                for i in 1...(rounds.count * 2) {
                    let idx = i % rounds.count
                    monitor.reset()
                    update(p) {
                        $0.roundIndex = idx
                        $0.phase = "lecture"
                        $0.questionIndex = 0
                        $0.completed = false
                    }
                    try? await Task.sleep(for: .seconds(2))
                    print(String(format: "[cycle] 切到第 %d 轮：第一帧 %.0f ms，最长一帧 %.0f ms", idx + 1, monitor.firstGap * 1000, monitor.maxGap * 1000))
                }
                print("[cycle] done")
            }
        }
        // 调试：-debugCycleSwitch 6 启动 6 秒后在本轮的讲解和做题之间来回切换 6 次，打印每次切换后的最长卡顿帧
        let switches = d.integer(forKey: "debugCycleSwitch")
        if switches > 0 {
            let monitor = FrameMonitor()
            Task {
                try? await Task.sleep(for: .seconds(6))
                for i in 0..<switches {
                    let target = i % 2 == 0 ? "lecture" : "questions"
                    monitor.reset()
                    let start = ProcessInfo.processInfo.systemUptime
                    update(p) { $0.phase = target }
                    try? await Task.sleep(for: .seconds(3))
                    print(String(format: "[switch] uptime %.2f 切到%@：第一帧 %.0f ms，最长一帧 %.0f ms", start,
                                 target == "lecture" ? "讲解" : "做题", monitor.firstGap * 1000, monitor.maxGap * 1000))
                }
                print("[switch] done")
            }
        }
        #endif
    }

    /// 下一题；本轮最后一题之后进入下一轮的讲解，最后一轮做完回到节列表
    private func advanceQuestion(_ p: SectionProgress, _ round: Round) {
        let isLastRound = p.roundIndex >= rounds.count - 1
        if p.questionIndex >= items(round).count - 1 && isLastRound { dismiss() }
        update(p) {
            if $0.questionIndex < items(round).count - 1 {
                $0.questionIndex += 1
            } else if isLastRound {
                $0.completed = true
            } else {
                $0.roundIndex += 1
                $0.phase = "lecture"
                $0.questionIndex = 0
            }
        }
    }

    private func update(_ p: SectionProgress, _ change: (SectionProgress) -> Void) {
        change(p)
        p.updatedAt = .now
        // 等这一帧画完再写数据库，不和切换抢主线程
        DispatchQueue.main.async { [context] in try? context.save() }
    }
}

/// 学习页中的一个位置：某一轮的讲解，或某一轮的某道题
struct StudyPosition {
    enum Page {
        case lecture
        case question(Int)
    }

    let roundIndex: Int
    let page: Page
}

func confidenceLabel(_ c: String) -> String { ChoiceConfidence(rawValue: c)?.label ?? c }

#if DEBUG
/// 调试用：记录两次屏幕刷新之间的最长间隔（即最卡的一帧）
final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var maxGap: CFTimeInterval = 0
    /// 切换后第一帧的间隔：点击之后界面多快有反应
    private(set) var firstGap: CFTimeInterval = 0

    override init() {
        super.init()
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    func reset() {
        maxGap = 0
        firstGap = 0
        last = 0
    }

    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 {
            let gap = l.timestamp - last
            if firstGap == 0 { firstGap = gap }
            maxGap = max(maxGap, gap)
        }
        last = l.timestamp
    }
}
#endif
