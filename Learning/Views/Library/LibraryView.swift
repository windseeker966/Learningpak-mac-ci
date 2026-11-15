import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 节的完成情况：每一轮的题（阅读轮含读后练习）都做过才算学完（书列表、节列表共用）
enum SectionCompletion {
    /// 统计完成情况用到的记录。书列表、节列表在出现时取一次，不用 @Query：
    /// 它们在导航栈里压在学习页下面，@Query 会在学习页每次保存（切换讲解、草稿自动保存）时重新取全部记录并重算，拖慢学习页
    struct Inputs {
        var attempts: [AttemptRecord] = []
        var subjective: [SubjectiveAttempt] = []
        var summaries: [PassageSummaryAttempt] = []
        var translations: [BackTranslationAttempt] = []
        /// 学习进度，按 SectionProgress.key
        var progresses: [String: SectionProgress] = [:]

        /// packID 为 nil 时取全部书的
        static func fetch(packID: String? = nil, in context: ModelContext) -> Inputs {
            let learn = AttemptMode.learn.rawValue, review = AttemptMode.review.rawValue
            var out = Inputs()
            out.attempts = (try? context.fetch(FetchDescriptor<AttemptRecord>(
                predicate: #Predicate { $0.mode == learn }))) ?? []
            out.subjective = (try? context.fetch(FetchDescriptor<SubjectiveAttempt>(
                predicate: #Predicate { $0.mode != review && $0.revealedAt != nil }))) ?? []
            out.summaries = (try? context.fetch(FetchDescriptor<PassageSummaryAttempt>())) ?? []
            out.translations = (try? context.fetch(FetchDescriptor<BackTranslationAttempt>())) ?? []
            let progresses = (try? context.fetch(FetchDescriptor<SectionProgress>())) ?? []
            out.progresses = Dictionary(progresses.filter { packID == nil || $0.packID == packID }.map { ($0.key, $0) },
                                        uniquingKeysWith: { a, _ in a })
            if let packID {
                out.attempts = out.attempts.filter { $0.packID == packID }
                out.subjective = out.subjective.filter { $0.packID == packID }
            }
            return out
        }

        func doneQuestions(_ pack: StudyPack) -> Set<String> {
            SectionCompletion.doneQuestions(pack: pack, attempts: attempts, subjective: subjective,
                                            summaries: summaries, translations: translations)
        }

        func progress(_ pack: StudyPack, _ s: SectionFile) -> SectionProgress? {
            progresses["\(pack.id)|\(s.section.id)"]
        }
    }

    /// 已做过的题：选择题有学习作答，主观题在学习页展开过答案，读后练习提交过（与学习页的「已做」一致）
    static func doneQuestions(pack: StudyPack, attempts: [AttemptRecord], subjective: [SubjectiveAttempt],
                              summaries: [PassageSummaryAttempt], translations: [BackTranslationAttempt]) -> Set<String> {
        let learn = attempts.filter { $0.packID == pack.id && $0.mode == AttemptMode.learn.rawValue }
        let revealed = subjective.filter { $0.packID == pack.id && $0.mode != AttemptMode.review.rawValue && $0.revealedAt != nil }
        var done = Set(learn.map(\.questionID)).union(revealed.map(\.questionID))
        let summarized = Set(summaries.filter { $0.packID == pack.id }.map(\.passageID))
        let translated = Set(translations.filter { $0.packID == pack.id }.map(\.sentenceKey))
        for passage in pack.chunks.values where passage.isPassage {
            if summarized.contains(passage.id) { done.insert("\(passage.id)#summary") }
            for (i, d) in (passage.backTranslation ?? []).enumerated()
                where translated.contains(BackTranslationAttempt.key(packID: pack.id, passageID: passage.id, english: d.en)) {
                done.insert("\(passage.id)#bt\(i + 1)")
            }
        }
        return done
    }

    /// 本轮题目都做过即算完成；没有题目的轮次学过去（当前轮之前或已学完）就算完成
    static func completedRounds(_ s: SectionFile, _ p: SectionProgress?, _ done: Set<String>, in pack: StudyPack) -> Int {
        s.rounds.enumerated().filter { i, r in
            let items = r.items(in: pack)
            return items.isEmpty ? (p.map { $0.completed || $0.roundIndex > i } ?? false) : items.allSatisfy(done.contains)
        }.count
    }

    static func learned(_ s: SectionFile, _ p: SectionProgress?, _ done: Set<String>, in pack: StudyPack) -> Bool {
        !s.rounds.isEmpty && completedRounds(s, p, done, in: pack) == s.rounds.count
    }
}

struct LibraryView: View {
    @Environment(PackStore.self) private var store
    /// 每本书已学完的节数，页面出现时统计（见 SectionCompletion.Inputs）
    @State private var learnedCounts: [String: Int] = [:]
    @State private var importing = false
    @State private var clearResult: String?
    @Environment(\.modelContext) private var context
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                if store.packs.isEmpty { emptyState }
                if !store.packs.isEmpty {
                    Section {
                        ForEach(store.packs) { pack in
                            NavigationLink {
                                BookSectionsView(pack: pack)
                            } label: {
                                bookRow(pack)
                            }
                        }
                    }
                }
                if !store.loadErrors.isEmpty {
                    Section("加载失败") {
                        ForEach(store.loadErrors, id: \.self) {
                            Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("学习")
            .onAppear(perform: refreshCounts)
            .onChange(of: store.packs.map(\.id)) { refreshCounts() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("刷新", systemImage: "arrow.clockwise") { store.reload() }
                    Button("导入教辅包", systemImage: "square.and.arrow.down") { importing = true }
                }
            }
            .refreshable { store.reload() }
            #if DEBUG
            // 调试：启动参数 -debugSection 1.2 直接进入该节
            .navigationDestination(isPresented: .constant(debugTarget != nil)) {
                if let t = debugTarget { StudySessionView(pack: t.0, section: t.1) }
            }
            // 调试：启动参数 -debugBookChat <book.id> 直接打开这本书的新 AI 提问
            .navigationDestination(isPresented: .constant(debugChatPack != nil)) {
                if let p = debugChatPack { BookChatView(pack: p, chat: nil) }
            }
            #endif
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                do {
                    try store.importFolder(at: result.get())
                } catch {
                    importError = error.localizedDescription
                }
            }
            #if DEBUG
            // 调试：启动参数 -debugClearSection 1.2 启动时清除该节记录
            .task(id: store.packs.count) {
                guard !Self.debugCleared, let id = UserDefaults.standard.string(forKey: "debugClearSection"),
                      let pack = store.packs.first(where: { $0.section(id) != nil }),
                      let s = pack.section(id) else { return }
                Self.debugCleared = true
                clearResult = BookSectionsView.clear(pack: pack, section: s, in: context)
            }
            .alert("已清除", isPresented: Binding(get: { clearResult != nil }, set: { if !$0 { clearResult = nil } })) {
                Button("好") { clearResult = nil }
            } message: {
                Text(clearResult ?? "")
            }
            #endif
            .alert("导入失败", isPresented: .constant(importError != nil)) {
                Button("好") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func refreshCounts() {
        let inputs = SectionCompletion.Inputs.fetch(in: context)
        var counts: [String: Int] = [:]
        for pack in store.packs {
            let answered = inputs.doneQuestions(pack)
            counts[pack.id] = pack.sections.filter { s in
                SectionCompletion.learned(s, inputs.progress(pack, s), answered, in: pack)
            }.count
        }
        learnedCounts = counts
    }

    private func bookRow(_ pack: StudyPack) -> some View {
        let chapters = Set(pack.sections.map(\.section.chapter)).count
        let done = learnedCounts[pack.id] ?? 0
        return HStack(spacing: 16) {
            Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(pack.title).font(.body.bold())
                Text("\(chapters) 章 · \(pack.sections.count) 节").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pack.sections.isEmpty {
                EmptyView()
            } else if done == pack.sections.count {
                Label("已学完", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Text("已学完 \(done) / \(pack.sections.count) 节").font(.callout)
                    .foregroundStyle(done > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, 6)
    }

    #if DEBUG
    private static var debugCleared = false

    private var debugChatPack: StudyPack? {
        guard let id = UserDefaults.standard.string(forKey: "debugBookChat") else { return nil }
        return store.packs.first { $0.id == id }
    }

    private var debugTarget: (StudyPack, SectionFile)? {
        guard let id = UserDefaults.standard.string(forKey: "debugSection") else { return nil }
        let packID = UserDefaults.standard.string(forKey: "debugPack")
        for pack in store.packs where packID == nil || pack.id == packID {
            if let s = pack.section(id) { return (pack, s) }
        }
        return nil
    }
    #endif

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("还没有教辅包", systemImage: "books.vertical").font(.title3.bold())
                Text("两种导入方式：")
                Text("1. 把教辅包文件夹（包含 book.yaml 的目录，如 os-2027）放进「文件」App › 我的 iPad › LearningPack，然后点右上角刷新。iPad 连接 Mac 时，也可以在访达的 iPad 页面 › 文件 › LearningPack 里直接拖入。")
                Text("2. 点右上角「导入教辅包」，从「文件」App 中选择教辅包文件夹。")
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        }
    }
}

/// 一本书的章节：按章分组列出各节，点进某节开始学习
struct BookSectionsView: View {
    let pack: StudyPack
    /// 本书的学习进度和已做的题，用来统计各节完整做过题的轮数；页面出现时取一次（见 SectionCompletion.Inputs）
    @State private var inputs = SectionCompletion.Inputs()
    /// 各轮讲解的提示词版本和讲解页写了草稿的轮次（按讲解的缓存键）；页面出现、生成讲解有进展时取一次
    @State private var lectureState: (versions: [String: Int], drafted: Set<String>) = ([:], [])
    @Environment(LectureBatch.self) private var batch
    @State private var clearTarget: ClearTarget?
    @State private var clearResult: String?
    @Environment(\.modelContext) private var context

    private struct ClearTarget {
        let pack: StudyPack
        let section: SectionFile
    }

    private func refresh() {
        inputs = SectionCompletion.Inputs.fetch(packID: pack.id, in: context)
        refreshLectureKeys()
    }

    private func refreshLectureKeys() {
        lectureState = LectureGeneration.cacheState(packID: pack.id, in: context)
    }

    /// 章名与该章的节，按 book.yaml 中的顺序
    private var chapters: [(title: String, sections: [SectionFile])] {
        var out: [(title: String, sections: [SectionFile])] = []
        for s in pack.sections {
            if let i = out.firstIndex(where: { $0.title == s.section.chapter }) {
                out[i].sections.append(s)
            } else {
                out.append((s.section.chapter, [s]))
            }
        }
        return out
    }

    var body: some View {
        let done = inputs.doneQuestions(pack)
        return List {
            Section {
                NavigationLink {
                    BookChatListView(pack: pack)
                } label: {
                    Label("AI 提问", systemImage: "bubble.left.and.text.bubble.right").font(.body.bold())
                }
                NavigationLink {
                    BookNotesView(pack: pack)
                } label: {
                    Label("笔记", systemImage: "note.text").font(.body.bold())
                }
            } footer: {
                Text("AI 提问：知道全书内容和你的进度，可跳到某一轮。笔记：各题的订正笔记（文字和手写）和自己添加的笔记")
            }
            ForEach(chapters, id: \.title) { chapter in
                Section {
                    ForEach(chapter.sections, id: \.section.id) { s in
                        NavigationLink {
                            StudySessionView(pack: pack, section: s)
                        } label: {
                            sectionRow(pack, s, done)
                        }
                        .swipeActions {
                            Button("清除记录", systemImage: "trash") {
                                clearTarget = ClearTarget(pack: pack, section: s)
                            }
                            .tint(.red)
                        }
                        .contextMenu {
                            Button("清除本节做题记录…", systemImage: "trash", role: .destructive) {
                                clearTarget = ClearTarget(pack: pack, section: s)
                            }
                        }
                    }
                } header: {
                    Text(chapter.title).font(.headline).textCase(nil)
                }
            }
        }
        .navigationTitle(pack.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        // 生成讲解有进展时更新「讲解已就绪」
        .onChange(of: batch.version) { refreshLectureKeys() }
        .confirmationDialog(
            "清除 \(clearTarget?.section.section.id ?? "") \(clearTarget?.section.section.title ?? "") 的做题记录？",
            isPresented: Binding(get: { clearTarget != nil }, set: { if !$0 { clearTarget = nil } }),
            titleVisibility: .visible,
            presenting: clearTarget
        ) { t in
            Button("清除", role: .destructive) {
                clearResult = Self.clear(pack: t.pack, section: t.section, in: context)
                clearTarget = nil
                refresh()
            }
        } message: { _ in
            Text("将删除本节的作答记录、复习队列、学习进度（回到第 1 轮）和主观题书写，无法恢复。AI 讲解会保留。")
        }
        .alert("已清除", isPresented: Binding(get: { clearResult != nil }, set: { if !$0 { clearResult = nil } })) {
            Button("好") { clearResult = nil }
        } message: {
            Text(clearResult ?? "")
        }
    }

    /// 清除一节的做题记录，返回给用户看的结果说明
    static func clear(pack: StudyPack, section: SectionFile, in context: ModelContext) -> String {
        do {
            let r = try RecordMaintenance.clearSection(
                packID: pack.id, sectionID: section.section.id,
                questionIDs: section.questions.map(\.id),
                subjectiveIDs: (section.subjective ?? []).map(\.id), in: context)
            return "删除了 \(r.attempts) 条作答记录、\(r.reviews) 道复习题，学习进度已重置。"
        } catch {
            return "清除失败：\(error.localizedDescription)"
        }
    }

    private func sectionRow(_ pack: StudyPack, _ s: SectionFile, _ doneQuestions: Set<String>) -> some View {
        let p = inputs.progress(pack, s)
        let total = s.rounds.count
        let done = SectionCompletion.completedRounds(s, p, doneQuestions, in: pack)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(s.section.id) \(s.section.title)").font(.body.bold())
                let live = (s.subjective ?? []).filter { $0.deprecated != true }
                let blanks = live.filter(\.isBlank).count, subjective = live.count - blanks
                Text("\(s.section.chapter)" + (s.section.pages.map { " · 第 \(pageText($0)) 页" } ?? "") + " · \(s.questions.count) 道选择题"
                     + (blanks > 0 ? " · \(blanks) 道填空题" : "")
                     + (subjective > 0 ? " · \(subjective) 道综合题" : "") + " · \(total) 轮")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            lectureStatus(pack, s, doneQuestions)
            // 每一轮都做完就算学完，不必点「完成本节」
            if SectionCompletion.learned(s, p, doneQuestions, in: pack) {
                Label("已学完", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else if done > 0 || p.map({ $0.completed || $0.roundIndex > 0 || $0.phase != "lecture" }) == true {
                Text("已完成 \(done) / \(total) 轮").font(.callout).foregroundStyle(.tint)
            } else {
                Text("未开始").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 一键生成本节讲解

    @ViewBuilder
    private func lectureStatus(_ pack: StudyPack, _ s: SectionFile, _ done: Set<String>) -> some View {
        let state = lectureState
        // 阅读轮、习题轮不讲解；全是这样的轮的节不显示讲解状态
        let lectureRounds = s.rounds.filter { !$0.skipsLecture(in: pack) }
        // 要生成的：没有讲解，或是还没学到的旧版（见 LectureGeneration.isReady）
        let pending = lectureRounds.filter { r in
            let key = LectureGeneration.cacheKey(pack: pack, section: s, round: r)
            return !LectureGeneration.isReady(version: state.versions[key], studied: r.questions.contains(where: done.contains),
                                              hasDraft: state.drafted.contains(key))
        }
        let missing = pending.count
        let outdated = pending.filter { state.versions[LectureGeneration.cacheKey(pack: pack, section: s, round: $0)] != nil }.count
        let job = batch.job(pack: pack, section: s)
        Group {
            if batch.isRunning(pack: pack, section: s), let job {
                HStack(spacing: 8) {
                    ProgressView(value: Double(job.done + job.failed), total: Double(max(job.total, 1)))
                        .frame(width: 80)
                    Text("讲解 \(job.done + job.failed)/\(job.total)").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("停止", systemImage: "stop.circle") { batch.cancel(pack: pack, section: s) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            } else if lectureRounds.isEmpty {
                EmptyView()
            } else if missing == 0 {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("讲解已就绪")
                }
                .font(.caption)
                .foregroundStyle(.green)
            } else {
                if job.map({ $0.failed > 0 }) == true && LLMConfig.backup() != nil {
                    Button {
                        batch.start(pack: pack, section: s, done: done, context: context, useBackup: true)
                    } label: {
                        Label("换备用模型重试", systemImage: "arrow.triangle.swap").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    batch.start(pack: pack, section: s, done: done, context: context)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                        Text(job.map { $0.failed > 0 } == true ? "重试 \(missing) 轮讲解"
                             : outdated > 0 ? "更新 \(missing) 轮讲解"
                             : missing == lectureRounds.count ? "生成本节讲解" : "生成剩余 \(missing) 轮讲解")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!pending.contains { LLMConfig.hasAvailableProvider($0.chunks.isEmpty ? .recap : .lecture) })
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
