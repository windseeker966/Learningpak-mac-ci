import SwiftData
import SwiftUI

/// 逐题复习，与学习时同一套作答流程。传入 blocks 时是一组一组地复习（见 ReviewBlockSession）：
/// 进度按这组算，热身题不开画布，最后一道没做对时补一道短题收尾，做完一组显示结束页（再来几道 / 结束）
struct ReviewSessionView: View {
    var blocks: ReviewBlockSession?
    var onClose: () -> Void

    @Environment(PackStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(StateCheckSession.self) private var stateCheck
    @Environment(\.scenePhase) private var scenePhase
    /// 这次要做的题；一组一组地复习时可能在末尾补一道
    @State private var queue: [ReviewItem]
    @State private var index = 0
    /// 这组做完，显示结束页
    @State private var finished = false
    @State private var resetZoomRequest = 0
    @AppStorage("draft.enabled") private var draftEnabled = true
    @State private var tapTargets = DraftTapTargets()
    /// 已提交作答的题（显示「回到最开始学这道题的地方」）
    @State private var submitted: Set<String> = []
    @State private var backTo: BackToStudyTarget?
    /// 选择题下方展开的 AI 改编（按题）；值变化即重新改编
    @State private var aiVariants: [String: UUID] = [:]
    @State private var aiVariantBackup: [String: Bool] = [:]
    /// 点了「重新改编」的题：不用上次存下的改编题
    @State private var aiVariantFresh: Set<String> = []

    init(items: [ReviewItem], blocks: ReviewBlockSession? = nil, onClose: @escaping () -> Void) {
        _queue = State(initialValue: items)
        self.blocks = blocks
        self.onClose = onClose
    }

    private enum Entry {
        case choice(ReviewItem, StudyPack, Question)
        case subjective(ReviewItem, StudyPack, SubjectiveQuestion)

        var item: ReviewItem {
            switch self {
            case .choice(let i, _, _), .subjective(let i, _, _): i
            }
        }

        var pack: StudyPack {
            switch self {
            case .choice(_, let p, _), .subjective(_, let p, _): p
            }
        }

        var questionID: String {
            switch self {
            case .choice(_, _, let q): q.id
            case .subjective(_, _, let q): q.id
            }
        }
    }

    private var draftKey: String? {
        guard !finished, index < entries.count else { return nil }
        let e = entries[index]
        return DraftKey.review(pack: e.pack.id, questionID: e.questionID)
    }

    /// 当前是热身题：不开画布、不给书写区，点下去就能答
    private var warmupCurrent: Bool {
        guard let blocks, index < entries.count else { return false }
        return blocks.isWarmup(entries[index].item)
    }

    private var canvasOn: Bool { draftEnabled && !warmupCurrent }

    private var entries: [Entry] {
        queue.compactMap { item in
            guard let pack = store.pack(item.packID) else { return nil }
            if let q = pack.questions[item.questionID] { return .choice(item, pack, q) }
            if let q = pack.subjective[item.questionID] { return .subjective(item, pack, q) }
            return nil
        }
    }

    /// 下一题；做完最后一题：一组一组地复习显示结束页，否则直接关闭
    private func next() {
        if index >= entries.count - 1 {
            if let blocks { finish(blocks) } else { onClose() }
        } else {
            index += 1
        }
    }

    private func finish(_ blocks: ReviewBlockSession) {
        let first = blocks.finishBlock()
        finished = true
        // 先做，再问累不累：做完今天的第一组问一句状态
        if first { stateCheck.firstBlockFinished() }
    }

    /// 再来一组
    private func startNext(_ blocks: ReviewBlockSession, size: Int) {
        queue = blocks.startBlock(size: size)
        index = 0
        submitted = []
        finished = false
    }

    /// 跳过当前题：不记作答，这道题仍然到期；一组一组地复习时今天不再出现
    private func skip() {
        guard index < entries.count else { return }
        let e = entries[index]
        ActivityLog.write("review_skip", ["pack": e.pack.id, "question": e.questionID])
        stateCheck.questionSkipped()
        blocks?.skip(e.item)
        next()
    }

    /// 答完一道（主观题为提交自评，correct 传 nil 由 blocks 查最近一次自评）
    private func answered(_ e: Entry, correct: Bool?) {
        submitted.insert(e.questionID)
        guard let blocks else { return }
        if let closer = blocks.answered(e.item, correct: correct, isLast: index >= entries.count - 1, in: context) {
            queue.append(closer)
        }
    }

    private var title: String {
        if finished { return blocks?.isDone == true ? "今天完成" : "这组做完了" }
        return "复习 \(min(index + 1, entries.count)) / \(entries.count)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if finished, let blocks {
                    endPage(blocks)
                } else {
                    page
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .backToStudyDestination($backTo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !finished {
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
                        // 提交或自评后卡片里有「下一题」，不再显示
                        if index < entries.count, !submitted.contains(entries[index].questionID) {
                            Button("跳过此题") { skip() }
                        }
                    }
                    Button("结束") { onClose() }
                }
            }
        }
        // 这组的用时只计 App 在前台、页面开着的时间
        .onAppear { blocks?.setActive(scenePhase == .active) }
        .onDisappear { blocks?.setActive(false) }
        .onChange(of: scenePhase) { blocks?.setActive(scenePhase == .active) }
    }

    private var page: some View {
        ZoomablePageScrollView(draftEnabled: canvasOn, resetScrollID: index,
                               resetZoomRequest: resetZoomRequest) {
            VStack(spacing: 20) {
                if index < entries.count {
                    let entry = entries[index]
                    let nextLabel = index == entries.count - 1 ? (blocks == nil ? "完成复习" : "这组做完") : "下一题"
                    ProgressView(value: Double(index), total: Double(entries.count))
                    switch entry {
                    case .choice(let item, let pack, let q):
                        let warmup = blocks?.isWarmup(item) == true
                        DetachableQuestionCard(pack: pack, question: q, mode: .review,
                                               onSubmitted: { answered(entry, correct: $0.isCorrect) },
                                               onAIVariant: {
                                                   aiVariantBackup[q.id] = false
                                                   aiVariantFresh.remove(q.id)
                                                   aiVariants[q.id] = UUID()
                                               },
                                               writing: warmup ? nil
                                                   : WritingSpec(sectionID: pack.questionSection[q.id] ?? "",
                                                                 draftKey: DraftKey.review(pack: pack.id, questionID: q.id),
                                                                 storage: .review),
                                               shuffleOptions: true,
                                               nextLabel: nextLabel) {
                            next()
                        }
                        .id(q.id)
                        // 点「AI改编」后在这里展开：和 AI 改编复习一样记录，做完可以不做原题直接下一题
                        if let token = aiVariants[q.id] {
                            InlineAIVariant(pack: pack, original: q,
                                            draftKey: DraftKey.review(pack: pack.id, questionID: q.id),
                                            practice: false, finishLabel: nextLabel,
                                            useBackup: aiVariantBackup[q.id] ?? false,
                                            reuse: !aiVariantFresh.contains(q.id),
                                            onRegenerate: {
                                                aiVariantBackup[q.id] = $0
                                                aiVariantFresh.insert(q.id)
                                                aiVariants[q.id] = UUID()
                                            },
                                            onClose: { aiVariants[q.id] = nil },
                                            onFinish: { next() })
                                .id(token)
                        }
                        if submitted.contains(q.id) {
                            BackToStudyButton(pack: pack, questionID: q.id) { backTo = $0 }
                        }
                    case .subjective(_, let pack, let q):
                        DetachableSubjectiveCard(pack: pack, question: q,
                                                 sectionID: pack.questionSection[q.id] ?? "",
                                                 mode: .review, nextLabel: nextLabel,
                                                 onAssessed: { answered(entry, correct: nil) },
                                                 variantAdvances: true) {
                            next()
                        }
                        .id(q.id)
                        if submitted.contains(q.id) {
                            BackToStudyButton(pack: pack, questionID: q.id) { backTo = $0 }
                        }
                    }
                }
                if canvasOn && index < entries.count { Color.clear.frame(height: 360) }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(draftPageSpace))
            .environment(\.draftTapTargets, tapTargets)
            .overlay {
                if canvasOn, let key = draftKey {
                    DraftCanvas(key: key, enabled: true, tapTargets: tapTargets).id(key)
                }
            }
        }
    }

    /// 一组做完：只说今天做了多久，不说还剩多少。今天的题做完只剩「结束」
    private func endPage(_ blocks: ReviewBlockSession) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(blocks.isDone ? "今天完成" : "这组做完了")
                .font(.system(size: 44, weight: .bold))
            Text("今天做了 \(blocks.minutesToday) 分钟")
                .font(.title3)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                // 做完两组后可以选更大的组；上次选的题数用醒目的按钮
                if !blocks.isDone {
                    ForEach(blocks.sizeOptions, id: \.self) { size in
                        let label = Label("再来 \(blocks.nextBlock(size: size).count) 道", systemImage: "arrow.right")
                            .font(.title3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        if size == blocks.defaultSize {
                            Button { startNext(blocks, size: size) } label: { label }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button { startNext(blocks, size: size) } label: { label }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                Button {
                    onClose()
                } label: {
                    Text("结束")
                        .font(.title3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
