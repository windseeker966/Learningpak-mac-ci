import SwiftData
import SwiftUI

/// 复习页：打开就是一个「做 N 道 · 约 M 分钟」的大按钮，一组一组地复习（见 ReviewBlockSession）；
/// 队列、各本书、生词本和表达本收在右上角「全部」里。间隔复习按 FSRS 记忆模型安排（见 ReviewScheduler）
struct ReviewView: View {
    @Environment(PackStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(StateCheckSession.self) private var stateCheck
    /// 复习队列、生词、表达和题目标记。不用 @Query：复习窗口开着时这一页压在下面，@Query 会在每次保存
    /// （AI 讲评草稿和流式输出的自动保存）后重新取全部记录并重算整页，让复习窗口打字、滚动卡顿。
    /// 出现时取一次，之后只在这几类记录或作答有增删改时重新取（见 Notification.touches）
    @State private var items: [ReviewItem] = []
    /// 正在进行的复习。必须存成状态：若在绑定里现场新建，每次刷新 id 都会变，窗口会反复关闭又弹出
    @State private var session: ReviewBatch?
    @State private var vocab: [VocabEntry] = []
    /// 正在背的单词；同样存成状态，打开后列表不随自评变化
    @State private var vocabSession: [VocabEntry]?
    /// AI 短文复习生词
    @State private var vocabPassage = false
    /// 说法卡（放进来的）
    @State private var phrases: [PhraseCard] = []
    /// 正在背的说法卡；存成状态，打开后列表不随自评变化
    @State private var phraseSession: [PhraseCard]?
    @State private var expressions: [ExpressionEntry] = []
    /// 题目的「重点」「已掌握」标记，显示在每行上
    @State private var marks: [QuestionMark] = []
    /// 正在复习的表达；存成状态，打开后列表不随自评变化
    @State private var expressionSession: [ExpressionEntry]?
    /// 一组一组地复习的进度
    @State private var blocks = ReviewBlockSession()
    /// 计算测速的记录。测速时每答一题都保存一次，只在打开这一页和测完关闭时重新取，不跟着每次保存刷新
    @State private var factDrills: [FactDrill] = []
    /// 正在测速（打开时的测速记录：有今天没做完的一轮就接着做，否则据此抽新的一轮）
    @State private var factStart: [FactDrill]?
    /// 「全部 › 计算测速」里点开的页面（背诵表或记录）
    @State private var factPage: FactPage?

    /// 队列里还能复习的题（教辅包还在、题还在）和其中到期的题。下面这些都在队列或进度变化时由 sync 算好存起来，
    /// 不在 body 里现算：首页和「全部」列表的每一行都会用到，每次刷新都重新过滤、估用时会让切换标签页卡顿
    @State private var active: [ReviewItem] = []
    @State private var due: [ReviewItem] = []

    private func kind(_ item: ReviewItem) -> ReviewPlan.Kind { ReviewScheduler.kind(of: item, in: store) }

    /// 今天要做的题（按时长从到期的题里挑出，见 ReviewScheduler.todayPlan），按做题顺序
    @State private var plan: [String] = []

    /// 今天还没做的题：计划里仍到期、今天没跳过的
    @State private var planned: [ReviewItem] = []
    @State private var plannedKeys: Set<String> = []

    /// 到期但今天不做的：超出今天时长顺延的，或今天跳过的
    @State private var deferred: [ReviewItem] = []

    /// 队列变了：重算今天的计划，记下今天到期过的题，更新一组一组复习的进度
    private func sync() {
        // 全由说法卡复习的题卡都自评过后退出复习队列（见 PhraseDeck.reviewable）
        let retired = PhraseDeck.retiredKeys(items, cards: phrases, store: store)
        active = items.filter { store.pack($0.packID)?.isReviewable($0.questionID) == true && !retired.contains($0.key) }
        due = active.filter(ReviewScheduler.isDue)
        plan = ReviewScheduler.todayPlan(due, all: active, kind: kind)
        syncPlanned()
        todayKeys = ReviewScheduler.recordToday(planned)
    }

    /// 计划或今天跳过的题变了：重算今天还没做的、顺延的，更新一组一组复习的进度
    private func syncPlanned() {
        planned = ReviewScheduler.remaining(plan: plan, due: due)
        plannedKeys = Set(planned.map(\.key))
        deferred = due.filter { !plannedKeys.contains($0.key) }
        blocks.update(planned: planned, all: active, kind: kind)
    }

    /// 预计用时（分钟，至少 1）
    private func minutes(_ list: [ReviewItem]) -> Int {
        max(Int((list.reduce(0) { $0 + (blocks.cost[$1.key] ?? 0) } / 60).rounded()), 1)
    }

    /// 今天到期过的题（含已经复习过、到期日已推后的），见 ReviewScheduler.todayKeys
    @State private var todayKeys = ReviewScheduler.todayKeys()

    private func isDoneToday(_ item: ReviewItem) -> Bool {
        ReviewScheduler.isDoneToday(item, todayKeys: todayKeys)
    }

    /// 今天的题：今天要做、还没复习的在前，今天已复习的在后
    private func today(in list: [ReviewItem]) -> [ReviewItem] {
        let keys = Set(list.map(\.key))
        return planned.filter { keys.contains($0.key) } + list.filter(isDoneToday)
    }

    /// 每本书在列表里直接列出的题数
    static let previewLimit = 8

    var body: some View {
        NavigationStack {
            startScreen
                .navigationTitle("复习")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            listPage
                        } label: {
                            Label("全部", systemImage: "list.bullet")
                        }
                    }
                }
                // 记下今天到期的题，做完后仍算今天的题；切回复习页时也记一次，跨过 0 点后换成新一天的
                .onAppear {
                    load()
                    sync()
                }
                .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
                    if note.touches([ReviewItem.self, VocabEntry.self, ExpressionEntry.self, QuestionMark.self, PhraseCard.self])
                        || note.insertsOrDeletes([AttemptRecord.self, SubjectiveAttempt.self, VariantAttempt.self]) {
                        load()
                        if note.touches([ReviewItem.self, PhraseCard.self]) { sync() }
                    }
                    // 手机上测的同步过来时（新增一轮）；测速中每题的保存只是修改，不在这里重取
                    if note.insertsOrDeletes([FactDrill.self]) { factDrills = FactDrill.all(in: context) }
                }
                // 复习时跳过的题今天不再算
                .onChange(of: blocks.day.skipped) { syncPlanned() }
                .onChange(of: store.packs.map(\.id)) { sync() }
                #if DEBUG
                // 调试：启动参数 -debugReviewNow YES 直接打开「立即复习全部」；-debugAIReviewNow YES 打开 AI 改编复习；
                // -debugReviewBlock YES 直接开始一组；-debugFactDrill YES 直接开始计算测速。只在启动后第一次进入复习页时生效，之后切换标签页不再自动打开
                .onAppear {
                    if items.isEmpty { load(); sync() }
                    if !Self.debugOpened, UserDefaults.standard.bool(forKey: "debugFactDrill") {
                        Self.debugOpened = true
                        startFactDrill()
                        return
                    }
                    guard !Self.debugOpened, session == nil, !active.isEmpty else { return }
                    if UserDefaults.standard.bool(forKey: "debugReviewNow") {
                        Self.debugOpened = true
                        session = ReviewBatch(items: active.sorted { $0.dueAt < $1.dueAt })
                    } else if UserDefaults.standard.bool(forKey: "debugAIReviewNow") {
                        Self.debugOpened = true
                        session = ReviewBatch(items: active.sorted { $0.dueAt < $1.dueAt }.filter(variantAllowed), ai: true)
                    } else if UserDefaults.standard.bool(forKey: "debugReviewBlock"), !blocks.remaining.isEmpty {
                        Self.debugOpened = true
                        // 有没做完的一组就接着做，和首页的按钮一样
                        session = ReviewBatch(items: blocks.currentBlock.isEmpty ? blocks.startBlock() : blocks.resume(),
                                              block: true)
                    }
                }
                #endif
                .fullScreenCover(isPresented: Binding(get: { vocabSession != nil }, set: { if !$0 { vocabSession = nil } })) {
                    VocabReviewSession(entries: vocabSession ?? []) { vocabSession = nil }
                        .stateCheckBanner()
                }
                .fullScreenCover(isPresented: Binding(get: { phraseSession != nil }, set: { if !$0 { phraseSession = nil } })) {
                    PhraseReviewSession(cards: phraseSession ?? []) { phraseSession = nil }
                        .stateCheckBanner()
                }
                .fullScreenCover(isPresented: $vocabPassage) {
                    VocabPassageReviewView { vocabPassage = false }
                        .stateCheckBanner()
                }
                .fullScreenCover(isPresented: Binding(get: { factStart != nil }, set: { if !$0 { factStart = nil } }),
                                 onDismiss: { factDrills = FactDrill.all(in: context) }) {
                    FactDrillView(drills: factStart ?? []) { factStart = nil }
                        .stateCheckBanner()
                }
                .fullScreenCover(isPresented: Binding(get: { expressionSession != nil },
                                                      set: { if !$0 { expressionSession = nil } })) {
                    ExpressionReviewSession(entries: expressionSession ?? []) { expressionSession = nil }
                        .stateCheckBanner()
                }
                .fullScreenCover(item: $session) { batch in
                    Group {
                        if batch.ai {
                            AIReviewSessionView(items: batch.items) { close(batch) }
                        } else {
                            ReviewSessionView(items: batch.items, blocks: batch.block ? blocks : nil) { close(batch) }
                        }
                    }
                    .stateCheckBanner()
                }
        }
    }

    private func load() {
        items = (try? context.fetch(FetchDescriptor<ReviewItem>(sortBy: [SortDescriptor(\.dueAt)]))) ?? []
        vocab = (try? context.fetch(FetchDescriptor<VocabEntry>())) ?? []
        phrases = PhraseDeck.all(in: context)
        expressions = (try? context.fetch(FetchDescriptor<ExpressionEntry>())) ?? []
        marks = (try? context.fetch(FetchDescriptor<QuestionMark>())) ?? []
        factDrills = FactDrill.all(in: context)
    }

    private func startFactDrill() {
        factStart = FactDrill.all(in: context)
    }

    private func close(_ batch: ReviewBatch) {
        session = nil
        if batch.block { blocks.setActive(false) }
        stateCheck.reviewClosed(startedAt: batch.openedAt)
    }

    #if DEBUG
    private static var debugOpened = false
    #endif

    // MARK: - 首页：一个按钮

    /// 没做完的一组：继续；今天还有题：做一组；都做完了：今天完成。不显示队列有多少题
    private var startScreen: some View {
        VStack(spacing: 20) {
            let current = blocks.currentBlock
            if !current.isEmpty {
                bigButton("继续", detail: "还剩 \(current.count) 道 · 约 \(minutes(current)) 分钟") {
                    session = ReviewBatch(items: blocks.resume(), block: true)
                }
            } else if !blocks.remaining.isEmpty {
                let next = blocks.nextBlock()
                bigButton("做 \(next.count) 道", detail: "约 \(minutes(next)) 分钟") {
                    session = ReviewBatch(items: blocks.startBlock(), block: true)
                }
                // 做完两组后可以换成更大或更小的组
                let others = blocks.sizeOptions.filter { $0 != blocks.defaultSize }
                if !others.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(others, id: \.self) { size in
                            let items = blocks.nextBlock(size: size)
                            Button("做 \(items.count) 道 · 约 \(minutes(items)) 分钟") {
                                session = ReviewBatch(items: blocks.startBlock(size: size), block: true)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.large)
                }
            } else if blocks.startedToday || !todayKeys.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.green)
                    Text("今天完成").font(.system(size: 44, weight: .bold))
                    if blocks.minutesToday > 0 {
                        Text("今天做了 \(blocks.minutesToday) 分钟").font(.title3).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("今天没有要复习的题").font(.title2).foregroundStyle(.secondary)
            }
            vocabButton
            phraseButton
            FactDrillHomeButton(drills: factDrills, onStart: startFactDrill)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    /// 今天还有要背的单词时显示在首页，不用进「全部」找；背完了不显示。
    /// 背过的词够多时下面再有一个「AI 短文复习生词」
    @ViewBuilder private var vocabButton: some View {
        let words = Vocab.dueToday(vocab)
        if !words.isEmpty {
            let newCount = words.filter(\.isNew).count
            Button { vocabSession = words } label: {
                VStack(spacing: 6) {
                    Label("背单词", systemImage: "character.book.closed").font(.title.bold())
                    Text("今日 \(words.count) 个" + (newCount > 0 ? "（新词 \(newCount)）" : "")).font(.title3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .frame(maxWidth: 720)
        }
        if canPassageReview {
            Button("AI 短文复习生词", systemImage: "doc.text.magnifyingglass") { vocabPassage = true }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.large)
        }
    }

    /// 今天还有要背的说法卡时显示在首页；背完了不显示
    @ViewBuilder private var phraseButton: some View {
        let cards = PhraseDeck.dueToday(phrases)
        if !cards.isEmpty {
            let newCount = cards.filter(\.isNew).count
            Button { phraseSession = cards } label: {
                VStack(spacing: 6) {
                    Label("说法卡", systemImage: "text.quote").font(.title.bold())
                    Text("今日 \(cards.count) 张" + (newCount > 0 ? "（新卡 \(newCount)）" : "")).font(.title3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .frame(maxWidth: 720)
        }
    }

    private var canPassageReview: Bool {
        vocab.lazy.filter { !$0.isNew }.prefix(Vocab.passageMinimum).count >= Vocab.passageMinimum
    }

    private func bigButton(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Text(title).font(.system(size: 56, weight: .bold))
                Text(detail).font(.title2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: 720, maxHeight: 440)
    }

    // MARK: - 全部：队列、各本书、生词本、表达本

    private var listPage: some View {
        List {
            Section {
                let todayAll = today(in: active)
                VStack(alignment: .leading, spacing: 12) {
                    Text(!planned.isEmpty ? "今天 \(planned.count) 道题 · 约 \(minutes(planned)) 分钟"
                         : todayAll.isEmpty && deferred.isEmpty ? "今天没有要复习的题"
                         : "今天的题已复习完")
                        .font(.title2.bold())
                    if !deferred.isEmpty {
                        HStack {
                            Text("其余到期的题顺延到之后几天。")
                            if planned.isEmpty {
                                Button("再做一些", systemImage: "plus.circle") {
                                    plan = ReviewScheduler.extendPlan(due, all: active, kind: kind)
                                    syncPlanned()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .font(.callout)
                    }
                    Text("答错或没把握的题会进入复习队列，按 FSRS 记忆模型安排：根据每次作答估计这道题记得多牢，在快要忘记（记得的概率降到 \(Int(ReviewScheduler.retention * 100))%，做一遍要很久的综合题最多再低 10 个百分点）时安排复习。答得越好、隔得越久还答对，间隔拉得越长；答错则缩短。点下面列表中的某道题可以单独立即复习。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if ReviewScheduler.dailyMinutes > 0 {
                        Text("每天按 \(ReviewScheduler.dailyMinutes) 分钟安排（可在设置里改）：到期的题多时，先做还记得、花时间少的题，其余顺延；顺延 \(ReviewPlan.overdueFirstDays) 天以上的排在最前。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    actionButtons(due: planned, today: todayAll, active: active, scope: "全部")
                    if active.count > todayAll.count {
                        Text("「立即复习全部」会提前复习未到期的题，结果同样计入复习安排；提前复习答对，间隔增长得少一些。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !todayAll.isEmpty {
                        Text("今天的题复习完后还在今天的列表里，可以「再复习一遍今天的题」或 AI 改编复习；先做改编题再做原题也一样。同一天再做一次按短期记忆计入复习安排，影响比隔天复习小。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !active.isEmpty {
                        Text("「AI 改编复习」改编今天的题（今天没有就改编队列里的全部），由 AI 参考原题和你以往做这道题的作答、错因和讲评，改编出一道新题来做。改编题的结果按原题的规则计入复习安排、错题订正和知识点掌握度，并供下次改编参考。改编题有错时可以标记，标记后不计入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            if !vocab.isEmpty { vocabSection }
            if store.packs.contains(where: { !$0.phrases.isEmpty }) { phraseSection }
            if !expressions.isEmpty { expressionSection }
            FactDrillSection(drills: factDrills, onStart: startFactDrill, onOpen: { factPage = $0 })

            // 按书分组
            ForEach(store.packs) { pack in
                let bookActive = active.filter { $0.packID == pack.id }
                if !bookActive.isEmpty {
                    let bookToday = today(in: bookActive)
                    let bookDue = bookToday.filter(ReviewScheduler.isDue)
                    let bookDeferred = deferred.filter { $0.packID == pack.id }
                    Section {
                        actionButtons(due: bookDue, today: bookToday, active: bookActive, scope: "本书")
                            .padding(.vertical, 4)
                        // 到期的排在前面，接着是今天已复习的；题多时只列前几道，其余点「查看全部」
                        let ordered = bookToday + bookDeferred + bookActive.filter {
                            !ReviewScheduler.isDue($0) && !isDoneToday($0)
                        }
                        ForEach(ordered.prefix(Self.previewLimit)) { row($0) }
                        if ordered.count > Self.previewLimit {
                            NavigationLink {
                                List(ordered) { row($0) }
                                    .navigationTitle(pack.title)
                                    .navigationBarTitleDisplayMode(.inline)
                            } label: {
                                Text("查看全部").foregroundStyle(.tint)
                            }
                        }
                    } header: {
                        HStack {
                            Text(pack.title).font(.headline).textCase(nil)
                            Spacer()
                            Text((!bookDue.isEmpty ? "今日 \(bookDue.count) 题" : bookToday.isEmpty ? ""
                                  : "今日 \(bookToday.count) 题已复习")
                                 + (bookDeferred.isEmpty ? "" : (bookDue.isEmpty && bookToday.isEmpty ? "" : " · ") + "有顺延"))
                                .font(.caption).textCase(nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("全部")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $factPage) { page in
            switch page {
            case .guide: FactGuideView()
            case .stats: FactStatsView(drills: factDrills)
            }
        }
    }

    /// 说法卡：今天要背的卡，和全部放进来的卡
    private var phraseSection: some View {
        let today = PhraseDeck.dueToday(phrases)
        return Section {
            HStack(spacing: 12) {
                if !today.isEmpty {
                    Button { phraseSession = today } label: {
                        Label("开始背说法卡", systemImage: "play.fill").foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                }
                NavigationLink {
                    PhraseListView()
                } label: {
                    Label("查看全部说法卡（\(phrases.count)）", systemImage: "text.quote")
                }
            }
            .padding(.vertical, 4)
            Text("固定说法（如「战略先导 → 建设教育强国」）。学过一道题的第二天起，这道题考到的说法按题放进来，每天最多 \(PhraseDeck.dailyNew) 张新卡（可在设置里改）；以前选错过的说法先按「重来」。看说法、说出指的是什么，再翻面自评。每个选项都有说法卡的题，卡都自评过后不再进复习队列；卡都背牢（间隔 \(Int(PhraseUnlock.spotCheckDays)) 天以上）、原题也这么久没做时，原题回来抽查一次，做错了，选错的选项对应的卡退回重来。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("说法卡").font(.headline).textCase(nil)
        }
    }

    /// 生词本：今天要背的词（到期的旧词 + 每日上限内的新词）
    private var vocabSection: some View {
        let today = Vocab.dueToday(vocab)
        let newCount = today.filter(\.isNew).count
        return Section {
            HStack(spacing: 12) {
                if !today.isEmpty {
                    Button { vocabSession = today } label: {
                        Label("开始背单词", systemImage: "play.fill").foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if canPassageReview {
                    Button("AI 短文复习", systemImage: "doc.text.magnifyingglass") { vocabPassage = true }
                        .buttonStyle(.bordered)
                }
                NavigationLink {
                    VocabListView()
                } label: {
                    Label("查看生词本", systemImage: "character.book.closed")
                }
            }
            .padding(.vertical, 4)
            Text("在阅读文章里划选加入的词。先看原句想意思，再翻面自评，按 FSRS 安排下次复习；每天最多开始 \(Vocab.dailyNewLimit) 个新词。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("「AI 短文复习」从背过的词里随机挑 \(VocabPassageSession.wordCount) 个（不管到没到期），由 AI 写进一篇短文；写出它们在文中的意思，AI 批改后按结论建议自评，确认后同样按 FSRS 安排下次复习。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("生词本").font(.headline).textCase(nil)
                Spacer()
                Text(today.isEmpty ? "今天的单词背完了" : "今日 \(today.count) 个（新词 \(newCount)）")
                    .font(.caption).textCase(nil)
            }
        }
    }

    /// 表达本：回译时没写对的表达，到期的换新句子复习
    private var expressionSection: some View {
        let due = ExpressionBook.dueToday(expressions)
        return Section {
            HStack(spacing: 12) {
                if !due.isEmpty {
                    Button { expressionSession = due } label: {
                        Label("开始复习表达", systemImage: "play.fill").foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                }
                NavigationLink {
                    ExpressionListView()
                } label: {
                    Label("查看表达本", systemImage: "text.book.closed")
                }
            }
            .padding(.vertical, 4)
            Text("回译时原句里没写出来或写错的句式和搭配。复习时 AI 用这个表达另编一句中文让你翻译（每次都是新句子），点评后自评，按 FSRS 安排下次复习。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("表达本").font(.headline).textCase(nil)
                Spacer()
                Text(due.isEmpty ? "今天的表达复习完了" : "今日 \(due.count) 个")
                    .font(.caption).textCase(nil)
            }
        }
    }

    /// 开始复习 / 再复习一遍今天的题 / 立即复习全部 / AI 改编复习（都是逐题一口气做完，不分组）
    private func actionButtons(due: [ReviewItem], today: [ReviewItem], active: [ReviewItem],
                               scope: String) -> some View {
        HStack(spacing: 12) {
            if !due.isEmpty {
                Button { session = ReviewBatch(items: due) } label: {
                    // 列表里的图标会沿用主题色，和蓝底同色看不见，显式设成白色
                    Label("一口气复习\(scope == "全部" ? "今天的题" : "本书今天的题")", systemImage: "play.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
            } else if !today.isEmpty {
                // 今天的题都复习过了，可以再做一遍
                Button { session = ReviewBatch(items: today) } label: {
                    Label("再复习一遍今天的题", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
            }
            // 不等到期，把队列里所有题（到期的排在前面）立即复习一遍
            if active.count > today.count {
                Button("立即复习\(scope)", systemImage: "bolt.fill") {
                    session = ReviewBatch(items: active.sorted { $0.dueAt < $1.dueAt })
                }
                .buttonStyle(.bordered)
            }
            if active.contains(where: variantAllowed) {
                // 改编今天的题（包括已经复习过的），今天没有题时改编队列里的全部；不出改编题的书（ai_variant: false）跳过
                let list = (today.isEmpty ? active.sorted { $0.dueAt < $1.dueAt } : today).filter(variantAllowed)
                Button("AI 改编复习", systemImage: "sparkles") {
                    session = ReviewBatch(items: list, ai: true)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(!aiAvailable || list.isEmpty)
            }
        }
        .controlSize(scope == "全部" ? .large : .regular)
    }

    /// 这道题所在的书能不能 AI 改编
    private func variantAllowed(_ item: ReviewItem) -> Bool {
        store.pack(item.packID)?.allowsAIVariant == true
    }

    private var aiAvailable: Bool {
        LLMConfig.hasAvailableProvider(.choiceVariant) || LLMConfig.hasAvailableProvider(.subjectiveVariant)
    }

    /// 点一行即立即单独复习这道题
    private func row(_ item: ReviewItem) -> some View {
        Button { session = ReviewBatch(items: [item]) } label: { rowContent(item) }
            .buttonStyle(.plain)
            .contextMenu {
                if variantAllowed(item) {
                    Button("AI 改编复习这道题", systemImage: "sparkles") {
                        session = ReviewBatch(items: [item], ai: true)
                    }
                    .disabled(!aiAvailable)
                }
                let starred = mark(item)?.starred == true
                Button(starred ? "取消重点" : "标为重点", systemImage: starred ? "star.slash" : "star") {
                    QuestionMark.update(packID: item.packID, questionID: item.questionID, in: context) { $0.starred.toggle() }
                }
            }
    }

    private func mark(_ item: ReviewItem) -> QuestionMark? {
        marks.first { $0.key == item.key }
    }

    /// 错题订正状态（规则同错题本）
    private func status(_ item: ReviewItem) -> CorrectionStatus? {
        WrongBook.status(WrongBook.outcomes(packID: item.packID, questionID: item.questionID, in: context),
                         masteredAt: mark(item)?.masteredAt)
    }

    private func rowContent(_ item: ReviewItem) -> some View {
        let due = ReviewScheduler.isDue(item)
        let postponed = due && !plannedKeys.contains(item.key)
        let doneToday = isDoneToday(item)
        let pack = store.pack(item.packID)
        let section = pack?.questionSection[item.questionID] ?? ""
        let title: String, stem: String
        if let q = pack?.questions[item.questionID] {
            title = "\(section) 第 \(q.num) 题"
            stem = q.stem
        } else if let q = pack?.subjective[item.questionID] {
            title = "\(section) \(q.kindLabel) \(q.num)"
            stem = q.stem ?? "（题面见原图）"
        } else {
            title = item.questionID
            stem = ""
        }
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.bold())
                    if mark(item)?.starred == true {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    if let s = status(item) {
                        Text(s.label).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(s.color.opacity(0.15), in: Capsule()).foregroundStyle(s.color)
                    }
                }
                Text(stem).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if doneToday {
                    Text("今天已复习 · 下次 \(item.dueAt.formatted(.dateTime.month().day()))")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Text(postponed ? "顺延" : due ? "今天" : item.dueAt.formatted(.dateTime.month().day()))
                        .font(.callout)
                        .foregroundStyle(postponed ? AnyShapeStyle(.secondary) : due ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                if let r = item.retrievability {
                    Text("记得的概率 \(Int((r * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ReviewBatch: Identifiable {
    let id = UUID()
    let openedAt = Date.now
    let items: [ReviewItem]
    /// AI 改编复习
    var ai = false
    /// 一组一组地复习（见 ReviewBlockSession）
    var block = false
}
