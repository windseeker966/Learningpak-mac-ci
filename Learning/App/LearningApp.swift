import SwiftData
import SwiftUI

@main
struct LearningApp: App {
    @State private var store = PackStore()
    @State private var lectureBatch = LectureBatch()
    @State private var stateCheck = StateCheckSession()
    @State private var driveBackup = DriveBackupSession()
    @State private var phoneSync = PhoneSyncSession()
    /// 在 App 里读到的是所有窗口合起来的状态：任一窗口在前台就是 active。
    /// 在单独作答窗口里和 GoodNotes 并排作答时主窗口在后台，也要算在前台
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        LLMPurpose.migrate()
        do {
            container = try ModelContainer(for: AttemptRecord.self, ReviewItem.self, SectionProgress.self,
                                           LectureCache.self, DraftInk.self, SubjectiveProgress.self,
                                           SubjectiveAttempt.self, VariantAttempt.self, QuestionMark.self,
                                           SavedVariant.self, PendingVariant.self, BookNote.self, VocabEntry.self,
                                           BackTranslationAttempt.self, PassageSummaryAttempt.self,
                                           ExpressionEntry.self, ExpressionAttempt.self, BookChat.self,
                                           StateCheck.self, VocabPassageAttempt.self, FactDrill.self,
                                           PhraseCard.self)
        } catch {
            fatalError("无法打开数据库：\(error)")
        }
        // backup.sh 以环境变量启动时先导出存档，在迁移改动记录之前
        if let raw = ProcessInfo.processInfo.environment[DataExport.environmentKey],
           let name = DataExport.sanitized(raw), let storeURL = container.configurations.first?.url {
            do {
                _ = try DataExport.export(storeURL: storeURL, name: name)
            } catch {
                try? FileManager.default.createDirectory(at: DataExport.directory, withIntermediateDirectories: true)
                try? error.localizedDescription.write(to: DataExport.directory.appending(path: "\(name).error"),
                                                      atomically: true, encoding: .utf8)
            }
        }
        // 在任何界面读写记录之前完成，避免与刚发生的作答竞争
        RecordMaintenance.purgeLegacyRecordsOnce(in: container.mainContext)
        RecordMaintenance.purgeAIVariantRecords(in: container.mainContext)
        RecordMaintenance.migrateVariantFaultsOnce(in: container.mainContext)
        ReviewScheduler.migrateOnce(in: container.mainContext)
        PendingAnswers.purgeStale()
        LectureCache.purgeMetaphors(in: container.mainContext)
        // import_vocab.sh 以环境变量启动时导入生词
        VocabImport.runIfRequested(in: container.mainContext)
        // 调出 GoodNotes 的链接：旧的会弹「不支持的文件类型」，换成默认值
        SubjectiveWindow.migrateCompanionURL()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-debugChatInputChecks") {
                    ChatInputChecksView()
                } else if ProcessInfo.processInfo.arguments.contains("-debugMathChecks") {
                    MathCompatibilityChecksView()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .environment(store)
                .environment(lectureBatch)
                .environment(stateCheck)
                .environment(driveBackup)
                .environment(phoneSync)
                .onAppear { store.reloadIfChanged() }
        }
        .modelContainer(container)
        // 学习时长、休息提醒、学习码、离开回来的询问按整个 App 在前台的时间算（见 scenePhase）
        .onChange(of: scenePhase, initial: true) { _, phase in
            ActivityLog.write("app_phase", ["phase": "\(phase)"])
            switch phase {
            case .active:
                stateCheck.appBecameActive(in: container.mainContext)
                driveBackup.backupIfDue(in: container.mainContext)
                phoneSync.appBecameActive(in: container.mainContext, store: store)
            case .background:
                stateCheck.appEnteredBackground()
                phoneSync.appEnteredBackground()
            default: break
            }
        }

        // 单独作答的窗口：和 GoodNotes 并排作答（见 SubjectiveWindow）
        WindowGroup("单独作答", id: SubjectiveWindow.sceneID) {
            SubjectiveWindowView()
                .environment(store)
                .environment(lectureBatch)
                .environment(stateCheck)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(PackStore.self) private var store
    @Environment(StateCheckSession.self) private var stateCheck
    @Environment(DriveBackupSession.self) private var driveBackup
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context
    /// 角标。不用 @Query：根视图在每次保存后都会重算（见 ReviewView 的说明），
    /// 只在复习记录或设置变化时重新计算
    @State private var badgeText: String?
    /// 今天做完过计算测速。测速时每答一题都保存一次，只在它变了时重算角标
    @State private var factDone = true
    @AppStorage(ReviewScheduler.dailyMinutesKey) private var dailyMinutes = 30
    @State private var tab: String

    /// 打开 App 落在学习页。
    /// 调试：启动参数 -debugTab analysis 直接打开某个标签页；-debugWebURL 打开浏览器
    init() {
        let defaults = UserDefaults.standard
        _tab = State(initialValue: defaults.string(forKey: "debugTab")
            ?? (defaults.string(forKey: "debugWebURL") != nil ? "web" : "learn"))
    }

    /// 角标：今天还没做的题约多少分钟（按每天的时长挑出，顺延和今天跳过的不算），加上今天还要背的单词数、说法卡数，
    /// 今天还没做计算测速时再加「测速」，如「12 分钟 · 30 词 · 15 卡 · 测速」；都做完了不显示。题不显示题数：数字越大越让人望而却步，时间才是能感受的量。
    /// 结果在 loadBadge 时缓存，不在每次 RootView body 重算时重新遍历队列。
    private func calculateBadge(for items: [ReviewItem], vocab: [VocabEntry], phrases: [PhraseCard],
                                factDone: Bool) -> String? {
        let words = Vocab.dueToday(vocab).count
        let cards = PhraseDeck.dueToday(phrases).count
        let parts = [reviewBadge(for: items), words > 0 ? "\(words) 词" : nil, cards > 0 ? "\(cards) 卡" : nil,
                     factDone ? nil : "测速"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func reviewBadge(for items: [ReviewItem]) -> String? {
        let active = PhraseDeck.reviewable(items, store: store, in: context)
        let due = active.filter(ReviewScheduler.isDue)
        let kind: (ReviewItem) -> ReviewPlan.Kind = { ReviewScheduler.kind(of: $0, in: store) }
        let plan = ReviewScheduler.todayPlan(due, all: active, kind: kind)
        let remaining = ReviewScheduler.remaining(plan: plan, due: due)
        guard !remaining.isEmpty else { return nil }
        let est = ReviewScheduler.estimatedSeconds(active, kind: kind)
        let minutes = max(Int((remaining.reduce(0) { $0 + (est[$1.key] ?? 0) } / 60).rounded()), 1)
        return "\(minutes) 分钟"
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("学习", systemImage: "book", value: "learn") { LibraryView() }
            Tab("复习", systemImage: "calendar.badge.clock", value: "review") { ReviewView() }
                .badge(badgeText.map { Text($0) })
            Tab("分析", systemImage: "chart.bar.xaxis", value: "analysis") { AnalysisView() }
            Tab("浏览器", systemImage: "safari", value: "web") { WebReaderView() }
            Tab("设置", systemImage: "gearshape", value: "settings") { SettingsView() }
        }
        .background(WindowReader { SubjectiveWindow.shared.registerMain($0?.windowScene) })
        // 从「文件」App 放入新包后回到 App 时自动刷新
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.reloadIfChanged()
                loadBadge()
            }
        }
        .onChange(of: tab) { _, tab in ActivityLog.write("tab_change", ["tab": tab]) }
        // 「浏览器」标签页的时间不算进手机学习码
        .onChange(of: tab, initial: true) { _, tab in stateCheck.setBrowsing(tab == "web") }
        .onAppear { loadBadge() }
        .onChange(of: dailyMinutes) { loadBadge() }
        .onChange(of: store.packs.map(\.id)) { loadBadge() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { note in
            if note.touches([ReviewItem.self, VocabEntry.self, PhraseCard.self]) {
                loadBadge()
            } else if note.touches([FactDrill.self]), FactDrill.doneToday(FactDrill.all(in: context)) != factDone {
                loadBadge()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ReviewScheduler.blocksDidChange)) { _ in loadBadge() }
        .stateCheckBanner()
        #if DEBUG
        .task { await debugSaveProbe() }
        #endif
    }

    private func loadBadge() {
        // 每天第一次（教辅包加载好后）放一批说法卡进来
        PhraseIntroduction.runIfDue(store: store, in: context)
        let items = (try? context.fetch(FetchDescriptor<ReviewItem>())) ?? []
        let vocab = (try? context.fetch(FetchDescriptor<VocabEntry>())) ?? []
        factDone = FactDrill.doneToday(FactDrill.all(in: context))
        badgeText = calculateBadge(for: items, vocab: vocab, phrases: PhraseDeck.all(in: context), factDone: factDone)
    }

    #if DEBUG
    /// 调试：-debugSaveProbe 10 启动 8 秒后改一条作答记录并保存，共 10 次，每次打印保存后最长一帧，
    /// 用来检查后台页面在每次保存（如 AI 讲评自动保存）后重算的开销
    private func debugSaveProbe() async {
        let n = UserDefaults.standard.integer(forKey: "debugSaveProbe")
        guard n > 0 else { return }
        let monitor = FrameMonitor()
        try? await Task.sleep(for: .seconds(8))
        var gaps: [Double] = []
        for _ in 0..<n {
            var d = FetchDescriptor<AttemptRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            d.fetchLimit = 1
            guard let a = try? context.fetch(d).first else { return }
            monitor.reset()
            let start = ProcessInfo.processInfo.systemUptime
            a.followUpCount += 1
            try? context.save()
            let saveMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try? await Task.sleep(for: .seconds(1))
            gaps.append(monitor.maxGap * 1000)
            print(String(format: "[saveprobe] save %.0f ms，之后最长一帧 %.0f ms", saveMS, monitor.maxGap * 1000))
        }
        print(String(format: "[saveprobe] done 平均最长一帧 %.0f ms", gaps.reduce(0, +) / Double(gaps.count)))
    }
    #endif
}
