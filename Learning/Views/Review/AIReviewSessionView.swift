import PencilKit
import SwiftData
import SwiftUI

/// AI 改编：逐题让 AI 在原题上改编出一道新题再作答。
/// 做当前题时在后台改编后两道题；改编失败可重试或跳过。每道改编题一页草稿，画布只在内存里：
/// 选择题的笔迹不保存；主观题的笔迹收起、自评时存进作答（VariantAttempt）。
/// 改编题的结果记一条 VariantAttempt：按原题的规则计入原题的复习安排、订正状态和知识点掌握度，并供下次改编参考。
struct AIVariantRunner: View {
    typealias Entry = VariantSession.Entry

    var finishLabel = "完成"
    /// 当前题变化时回报当前变式题的 id（nil 表示正在改编或已做完），外层据此切换草稿画布
    var onCurrentChange: (String?) -> Void = { _ in }
    var onFinish: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var session: VariantSession

    init(entries: [Entry], finishLabel: String = "完成", onCurrentChange: @escaping (String?) -> Void = { _ in },
         onFinish: @escaping () -> Void = {}) {
        self.finishLabel = finishLabel
        self.onCurrentChange = onCurrentChange
        self.onFinish = onFinish
        _session = State(initialValue: VariantSession(entries: entries))
    }

    private var entries: [Entry] { session.entries }
    private var index: Int { session.index }
    private var current: QuestionVariant.Generated? { session.current }

    var body: some View {
        VStack(spacing: 20) {
            if entries.isEmpty {
                Card { Text("没有可以改编的题。").foregroundStyle(.secondary) }
            } else if index < entries.count {
                ProgressView(value: Double(index), total: Double(entries.count))
                switch entries[index] {
                case .choice(let pack, let original):
                    choiceVariant(pack, original)
                case .subjective(let pack, let original):
                    let title = "AI 改编 · 改编自 \(pack.questionSection[original.id] ?? "") \(original.kindLabel) \(original.num)"
                    switch session.subjectiveResults[index] {
                    case .success(let g):
                        let id = session.subjectiveReady ?? ""
                        DetachableSubjectiveVariantCard(pack: pack, original: original,
                                                        sectionID: pack.questionSection[original.id] ?? "",
                                                        draftKey: Self.draftKey(id), title: title,
                                                        closeLabel: index == entries.count - 1 ? finishLabel : "下一题",
                                                        prepared: (id, g),
                                                        onRegenerate: { session.regenerate(useBackup: $0) },
                                                        onNext: { advance() })
                            .id(id)
                    case .failure(let error):
                        Label(title, systemImage: "wand.and.stars").font(.callout).foregroundStyle(.purple)
                        failureCard(error)
                    case nil:
                        Label(title, systemImage: "wand.and.stars").font(.callout).foregroundStyle(.purple)
                        loadingCard
                    }
                }
            }
        }
        .onAppear {
            session.start(in: context)
            report()
        }
        .onDisappear { session.cancel() }
        .onChange(of: index) { report() }
        .onChange(of: current?.question.id) { report() }
        .onChange(of: session.subjectiveReady) { report() }
    }

    @ViewBuilder
    private func choiceVariant(_ pack: StudyPack, _ original: Question) -> some View {
                header(pack, original)
                switch session.results[index] {
                case .success(let g):
                    DetachableQuestionCard(pack: pack, question: g.question, mode: .aiReview,
                                           writing: WritingSpec(sectionID: pack.questionSection[original.id] ?? "",
                                                                draftKey: Self.draftKey(g.question.id), storage: .memory),
                                           nextLabel: index == entries.count - 1 ? finishLabel : "下一题") { advance() }
                        .id(g.question.id)
                case .failure(let error):
                    failureCard(error)
                case nil:
                    loadingCard
                }
    }

    private func failureCard(_ error: Error) -> some View {
        Card {
            Label("改编失败", systemImage: "exclamationmark.triangle").font(.headline)
                .foregroundStyle(.orange)
            Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
            HStack {
                AIRetryButtons { session.regenerate(useBackup: $0) }
                Button("跳过这道题") { advance() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .draftTappable()
            }
        }
    }

    private var loadingCard: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView()
                Text("AI 正在参考原题和你以往的作答改编新题…").foregroundStyle(.secondary)
            }
        }
    }

    /// 变式题页面的草稿键（画布只在内存里）
    static func draftKey(_ variantID: String) -> String { "ai|\(variantID)" }

    private func header(_ pack: StudyPack, _ original: Question) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label("AI 改编 · 改编自 \(pack.questionSection[original.id] ?? "") 第 \(original.num) 题",
                  systemImage: "wand.and.stars")
                .font(.callout).foregroundStyle(.purple)
            Spacer()
            if let usage = current?.usage { ModelBadge(usage: usage) }
            if current != nil {
                RegenerateMenu { session.regenerate(useBackup: $0) }
                    .font(.callout)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func report() {
        onCurrentChange(session.currentVariantID)
    }

    private func advance() {
        // 做完最后一题直接结束
        if !session.advance() { onFinish() }
    }
}

/// 原题下方展开的一道选择题 AI 改编。
/// 学习页（practice）只做练习：作答什么都不记，改编出的题目另存为 SavedVariant 供之后查看。
/// 复习页和 AI 改编复习一样：作答记 VariantAttempt，按原题的规则计入原题；做完点底部按钮（「下一题」）直接进入下一题。
/// 整块是草稿页的临时区域：其中的笔迹不保存，关闭时一并清掉
struct InlineAIVariant: View {
    let pack: StudyPack
    let original: Question
    let draftKey: String
    let practice: Bool
    /// 改编题提交后底部按钮的文字和动作；复习页是「下一题」
    var finishLabel: String
    var onRegenerate: (Bool) -> Void
    var onClose: () -> Void
    var onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @State private var session: ChoiceVariantGeneration

    static let anchorNames = ["ai-variant", "ai-writing"]

    /// useBackup：改用备用供应商的默认模型改编；onFinish 为 nil 时底部按钮也是收起
    /// reuse：复习页展开时先用上次改编好、还没做的题；重新改编时为 false
    init(pack: StudyPack, original: Question, draftKey: String, practice: Bool = true, finishLabel: String = "收起",
         useBackup: Bool = false, reuse: Bool = true, onRegenerate: @escaping (Bool) -> Void,
         onClose: @escaping () -> Void, onFinish: (() -> Void)? = nil) {
        self.pack = pack
        self.original = original
        self.draftKey = draftKey
        self.practice = practice
        self.finishLabel = finishLabel
        self.onRegenerate = onRegenerate
        self.onClose = onClose
        self.onFinish = onFinish ?? onClose
        _session = State(initialValue: ChoiceVariantGeneration(pack: pack, original: original, practice: practice,
                                                               useBackup: useBackup, reuse: reuse))
    }

    private var result: Result<QuestionVariant.Generated, Error>? { session.result }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(practice ? "AI 改编练习 · 只保存题目，作答不记录" : "AI 改编 · 改编自本题，按原题的规则计入复习安排",
                      systemImage: "wand.and.stars")
                    .font(.callout).foregroundStyle(.purple)
                Spacer()
                if case .success(let g) = result, let usage = g.usage { ModelBadge(usage: usage) }
                if result != nil {
                    RegenerateMenu { onRegenerate($0) }
                        .font(.callout).buttonStyle(.borderless)
                }
                Button("关闭", systemImage: "xmark.circle") { onClose() }
                    .font(.callout).buttonStyle(.borderless).draftTappable()
            }
            switch result {
            case .success(let g):
                QuestionCard(pack: pack, question: g.question, mode: practice ? .aiPractice : .aiReview,
                             writing: WritingSpec(sectionID: pack.questionSection[original.id] ?? "",
                                                  draftKey: draftKey, storage: .memory, anchorName: Self.anchorNames[1]),
                             nextLabel: finishLabel) { onFinish() }
                    .id(g.question.id)
            case .failure(let error):
                Card {
                    Label("改编失败", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    AIRetryButtons { onRegenerate($0) }
                }
            case nil:
                Card {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("AI 正在参考这道题和你以往的作答改编新题…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.purple.opacity(0.25)))
        .draftInkAnchor(draftKey, name: Self.anchorNames[0], transient: true)
        .onAppear { session.start(in: context) }
        .onDisappear {
            session.cancel()
            DraftAnchors.clearTransient(draftKey, names: Self.anchorNames)
        }
    }
}

/// 一道主观题的 AI 改编：标题、改编中、改编失败可重试；改编好后交给 SubjectiveCard（改编题模式）作答，记 VariantAttempt。
/// 整块是草稿页的临时区域：其中的笔迹不随页面保存，收起、重做、自评时存进这次作答。
/// 原题下方展开（学习页、复习页、错题本）和复习页逐题改编共用
struct SubjectiveVariantCard: View {
    let pack: StudyPack
    let original: SubjectiveQuestion
    let title: String
    /// 底部收起按钮的文字；复习页逐题改编时是「下一题」
    var closeLabel = "收起"
    /// 标题右边的「关闭」
    var showsClose = true
    /// 复习页逐题改编：有了结果才能下一题
    var requireResult = false
    /// 外面已改编好的题（复习页提前改编）；nil 时打开后自己改编
    var prepared: (id: String, generated: QuestionVariant.SubjectiveGenerated)? = nil
    var onRegenerate: (Bool) -> Void
    var onClose: () -> Void
    /// 底部按钮（closeLabel）的动作；复习页原题下方展开时是下一题
    var onFinish: () -> Void

    /// 在页面草稿画布上手写；单独的主观题窗口里没有画布，改为贴图片作答，也不报书写区位置
    var inkInput = true
    /// 「单独窗口作答」（AI 改编复习）；nil 时不显示
    var onDetach: (() -> Void)? = nil

    @Environment(\.modelContext) private var context
    @State private var generation: SubjectiveVariantGeneration
    /// 改编流程由这里建、只在这里用（复习页逐题改编）；否则由外面持有，离开屏幕时不停止改编（见 SubjectiveCard.VariantSlot）
    private let ownsGeneration: Bool

    static let anchorNames = ["ai-variant", "ai-writing"]

    /// practice：学习页的改编练习，作答照存，不计入复习安排；useBackup：改用备用供应商的默认模型改编
    init(pack: StudyPack, original: SubjectiveQuestion, sectionID: String, draftKey: String, title: String,
         closeLabel: String = "收起", showsClose: Bool = true, requireResult: Bool = false, practice: Bool = false,
         useBackup: Bool = false, prepared: (id: String, generated: QuestionVariant.SubjectiveGenerated)? = nil,
         onRegenerate: @escaping (Bool) -> Void, onClose: @escaping () -> Void, onFinish: (() -> Void)? = nil) {
        self.pack = pack
        self.original = original
        self.title = title
        self.closeLabel = closeLabel
        self.showsClose = showsClose
        self.requireResult = requireResult
        self.prepared = prepared
        self.onRegenerate = onRegenerate
        self.onClose = onClose
        self.onFinish = onFinish ?? onClose
        _generation = State(initialValue: SubjectiveVariantGeneration(
            pack: pack, original: original, sectionID: sectionID, draftKey: draftKey, practice: practice,
            useBackup: useBackup))
        ownsGeneration = true
    }

    /// 原题下方展开：改编流程由外面持有，主窗口和单独窗口之间转来转去时接着用
    init(generation: SubjectiveVariantGeneration, title: String, closeLabel: String, showsClose: Bool = true,
         requireResult: Bool, inkInput: Bool, onDetach: (() -> Void)? = nil, onRegenerate: @escaping (Bool) -> Void,
         onClose: @escaping () -> Void, onFinish: (() -> Void)? = nil) {
        pack = generation.pack
        original = generation.original
        self.title = title
        self.closeLabel = closeLabel
        self.showsClose = showsClose
        self.requireResult = requireResult
        self.inkInput = inkInput
        self.onDetach = onDetach
        self.onRegenerate = onRegenerate
        self.onClose = onClose
        self.onFinish = onFinish ?? onClose
        _generation = State(initialValue: generation)
        ownsGeneration = false
    }

    /// 报给草稿画布的锚点所在页；单独窗口里不报
    private var anchorKey: String { inkInput ? generation.draftKey : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: "wand.and.stars")
                    .font(.callout).foregroundStyle(.purple)
                Spacer()
                if case .success(let g) = generation.result, let usage = g.usage { ModelBadge(usage: usage) }
                if generation.result != nil {
                    RegenerateMenu { useBackup in
                        generation.session?.finishVariant(autoAssess: false)
                        onRegenerate(useBackup)
                    }
                    .font(.callout).buttonStyle(.borderless)
                }
                if showsClose {
                    Button("关闭", systemImage: "xmark.circle") {
                        generation.session?.finishVariant(autoAssess: false)
                        onClose()
                    }
                    .font(.callout).buttonStyle(.borderless).draftTappable()
                }
            }
            if let session = generation.session {
                SubjectiveCard(session: session, inkInput: inkInput, onDetach: onDetach, requireResult: requireResult,
                               nextLabel: closeLabel, onNext: onFinish)
            } else if case .failure(let error) = generation.result {
                Card {
                    Label("改编失败", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                    Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                    AIRetryButtons { onRegenerate($0) }
                }
            } else {
                Card {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("AI 正在参考这道题和你以往的批改记录改编新题…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.purple.opacity(0.25)))
        .draftInkAnchor(anchorKey, name: Self.anchorNames[0], transient: true)
        .onAppear { generation.start(prepared: prepared, in: context) }
        .onDisappear {
            // 先把改编区的笔迹存进作答，再清掉
            if ownsGeneration { generation.close() } else { generation.leave() }
            if inkInput { DraftAnchors.clearTransient(anchorKey, names: Self.anchorNames) }
        }
    }
}

/// 复习页的 AI 改编：全屏逐题
struct AIReviewSessionView: View {
    let items: [ReviewItem]
    var onClose: () -> Void

    @Environment(PackStore.self) private var store
    @State private var variantID: String?
    @State private var resetZoomRequest = 0
    @AppStorage("draft.enabled") private var draftEnabled = true
    @State private var tapTargets = DraftTapTargets()

    private var entries: [AIVariantRunner.Entry] {
        items.compactMap { item in
            guard let pack = store.pack(item.packID), pack.allowsAIVariant else { return nil }
            if let q = pack.questions[item.questionID] { return .choice(pack, q) }
            if let q = pack.subjective[item.questionID] { return .subjective(pack, q) }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            ZoomablePageScrollView(draftEnabled: draftEnabled, resetScrollID: variantID ?? "",
                                   resetZoomRequest: resetZoomRequest) {
                VStack(spacing: 20) {
                    AIVariantRunner(entries: entries, finishLabel: "完成复习",
                                    onCurrentChange: { variantID = $0 }, onFinish: onClose)
                    if draftEnabled && variantID != nil { Color.clear.frame(height: 360) }
                }
                .padding(24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .coordinateSpace(.named(draftPageSpace))
                .environment(\.draftTapTargets, tapTargets)
                .overlay {
                    if let id = variantID {
                        let key = AIVariantRunner.draftKey(id)
                        DraftCanvas(key: key, enabled: draftEnabled, tapTargets: tapTargets, persist: false).id(key)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AI 改编复习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button(draftEnabled ? "关闭草稿模式" : "开启草稿模式",
                               systemImage: draftEnabled ? "pencil.slash" : "pencil.tip") { draftEnabled.toggle() }
                        Button("恢复原大小", systemImage: "arrow.down.right.and.arrow.up.left") { resetZoomRequest += 1 }
                    } label: {
                        Label("草稿", systemImage: draftEnabled ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    } primaryAction: {
                        draftEnabled.toggle()
                    }
                    StateCheckMenu()
                    Button("结束") { onClose() }
                }
            }
        }
    }
}
