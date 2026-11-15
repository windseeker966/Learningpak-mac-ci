import PencilKit
import SwiftData
import SwiftUI

/// 表达复习：每个表达由 AI 另编一句中文（话题与原句不同，也避开以往出过的），学生手写或键盘输入英文，
/// AI 点评这个表达用对没有，再自评，按 FSRS 安排下次复习。做当前句时在后台出下一句；做完自动关闭。
/// 书写区和笔迹只在内存里，提交的截图存进 ExpressionAttempt
struct ExpressionReviewSession: View {
    let entries: [ExpressionEntry]
    let onClose: () -> Void

    @State private var index = 0
    @State private var resetZoomRequest = 0
    @AppStorage("draft.enabled") private var draftEnabled = true
    @State private var tapTargets = DraftTapTargets()

    private var draftKey: String? {
        index < entries.count ? "expr|\(entries[index].key)|\(index)" : nil
    }

    var body: some View {
        NavigationStack {
            ZoomablePageScrollView(draftEnabled: draftEnabled, resetScrollID: index, resetZoomRequest: resetZoomRequest) {
                VStack(spacing: 20) {
                    ExpressionQuestionList(entries: entries, index: $index, onFinish: onClose)
                    if draftEnabled { Color.clear.frame(height: 360) }
                }
                .padding(24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .coordinateSpace(.named(draftPageSpace))
                .environment(\.draftTapTargets, tapTargets)
                .overlay {
                    if let key = draftKey {
                        DraftCanvas(key: key, enabled: draftEnabled, tapTargets: tapTargets, persist: false).id(key)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("表达复习 \(min(index + 1, entries.count)) / \(entries.count)")
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
                    Button("结束") { onClose() }
                }
            }
        }
    }
}

/// 逐个表达出题、作答；提前准备下一句
private struct ExpressionQuestionList: View {
    let entries: [ExpressionEntry]
    @Binding var index: Int
    let onFinish: () -> Void

    @Environment(\.modelContext) private var context
    @State private var questions: [Int: Result<ExpressionQuestion, Error>] = [:]
    @State private var tasks: [Int: Task<Void, Never>] = [:]

    var body: some View {
        VStack(spacing: 20) {
            if index < entries.count {
                ProgressView(value: Double(index), total: Double(entries.count))
                switch questions[index] {
                case .success(let q):
                    ExpressionQuestionCard(entry: entries[index], question: q, draftKey: "expr|\(entries[index].key)|\(index)") {
                        advance()
                    }
                    .id(index)
                case .failure(let error):
                    Card {
                        Label("出题失败", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                        Text(error.localizedDescription).font(.callout).foregroundStyle(.secondary)
                        HStack {
                            AIRetryButtons { prepare(index, force: true, useBackup: $0) }
                            Button("跳过") { advance() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .draftTappable()
                        }
                    }
                case nil:
                    Card {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("AI 正在用「\(entries[index].expression)」编一句新的中文…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear {
            prepare(0)
            prepare(1)
        }
        .onDisappear { tasks.values.forEach { $0.cancel() } }
    }

    private func advance() {
        // 做完最后一个直接结束
        if index >= entries.count - 1 { onFinish(); return }
        index += 1
        prepare(index)
        prepare(index + 1)
    }

    private func prepare(_ i: Int, force: Bool = false, useBackup: Bool = false) {
        guard i < entries.count, force || (questions[i] == nil && tasks[i] == nil) else { return }
        let entry = entries[i]
        let pendingKey = PendingAnswers.expressionKey(entryKey: entry.key)
        // 上次出了题还没提交的接着做这一句
        if !force, let p = PendingAnswers.load(PendingAnswers.Expression.self, key: pendingKey)?.value {
            questions[i] = .success(ExpressionQuestion(chinese: p.chinese, reference: p.reference))
            return
        }
        let user = ReadingPracticePrompts.expressionQuestionUser(entry: entry,
                                                                history: ExpressionBook.attempts(of: entry, in: context))
        let config = useBackup ? (LLMConfig.backup() ?? .current(.readingPractice)) : .current(.readingPractice)
        tasks[i]?.cancel()
        questions[i] = nil
        tasks[i] = Task {
            do {
                guard LLMConfig.hasAvailableProvider(.readingPractice) else { throw LLMError.notConfigured }
                let result = try await LLMClient(config: config, backup: useBackup ? nil : .backup())
                    .complete(system: ReadingPracticePrompts.expressionQuestionSystem,
                              messages: [ChatTurn(role: .user, text: user)], maxTokens: 600)
                guard !Task.isCancelled else { return }
                let q = try ExpressionQuestion(result.text)
                questions[i] = .success(q)
                // 出好的句子先存下：没做完就离开，下次还做这一句
                PendingAnswers.save(PendingAnswers.Expression(chinese: q.chinese, reference: q.reference,
                                                              typed: "", usedHint: false), key: pendingKey)
            } catch {
                guard !Task.isCancelled else { return }
                questions[i] = .failure(error)
            }
        }
    }
}

/// AI 出的一句：中文和参考英译
struct ExpressionQuestion {
    let chinese: String
    let reference: String

    init(chinese: String, reference: String) {
        self.chinese = chinese
        self.reference = reference
    }

    struct InvalidOutput: LocalizedError {
        var errorDescription: String? { "AI 的回答不是预期的格式，请重试。" }
    }

    /// 从回答中取出 JSON 对象（容忍前后多余的文字或代码块标记）
    init(_ text: String) throws {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw InvalidOutput()
        }
        struct Raw: Decodable { let zh: String; let reference: String }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(text[start...end].utf8)),
              !raw.zh.isEmpty else { throw InvalidOutput() }
        chinese = raw.zh
        reference = raw.reference
    }
}

/// 一句表达复习：看中文写英文（可先看提示），提交后 AI 点评，再自评
private struct ExpressionQuestionCard: View {
    let entry: ExpressionEntry
    let question: ExpressionQuestion
    let draftKey: String
    let onNext: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(PackStore.self) private var store
    @State private var typed = ""
    @State private var showHint = false
    @State private var areaFrames: [Int: CGRect] = [:]
    @State private var attempt: ExpressionAttempt?
    @State private var runner = StreamRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                HStack {
                    Text("用学过的表达翻译").font(.headline)
                    Spacer()
                    if !showHint && attempt == nil {
                        Button("看提示：要用的表达", systemImage: "lightbulb") { showHint = true }
                            .buttonStyle(.borderless)
                            .draftTappable()
                    }
                }
                Text(question.chinese).font(.title3).lineSpacing(6).textSelection(.enabled)
                if showHint || attempt != nil {
                    Text("要用的表达：\(entry.expression)").font(.callout).foregroundStyle(.orange)
                }
            }
            if attempt == nil {
                TextField("也可以用键盘输入（手写时留空）", text: $typed, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 19, design: .serif))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    .draftTappable()
            }
            if let pack = store.pack(entry.packID) {
                ChoiceWritingSection(pack: pack, sectionID: "", questionID: draftKey, draftKey: draftKey, storage: .memory,
                                     accessory: AnyView(submitButtons), initialMemoryAreas: 1, areaFrames: $areaFrames)
            } else {
                submitButtons
            }
            if let attempt { result(attempt) }
        }
        .onAppear(perform: restorePending)
        .onDisappear { runner.cancel() }
        .onChange(of: typed) { savePending() }
        .onChange(of: showHint) { savePending() }
    }

    private var pendingKey: String { PendingAnswers.expressionKey(entryKey: entry.key) }

    /// 上次没提交的键盘输入、看没看提示（同一句才算）
    private func restorePending() {
        guard attempt == nil, let p = PendingAnswers.load(PendingAnswers.Expression.self, key: pendingKey)?.value,
              p.chinese == question.chinese else { return }
        typed = p.typed
        showHint = p.usedHint
    }

    private func savePending() {
        guard attempt == nil else { return }
        PendingAnswers.save(PendingAnswers.Expression(chinese: question.chinese, reference: question.reference,
                                                      typed: typed, usedHint: showHint), key: pendingKey)
    }

    @ViewBuilder
    private var submitButtons: some View {
        if attempt == nil {
            HStack(spacing: 12) {
                Button("提交，请 AI 点评", systemImage: "paperplane") { submit(skipped: false) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .draftTappable()
                Button("写不出来，看答案") { submit(skipped: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .draftTappable()
            }
        }
    }

    @ViewBuilder
    private func result(_ a: ExpressionAttempt) -> some View {
        if !a.answer.isEmpty {
            Card {
                Text("键盘输入").font(.caption).foregroundStyle(.secondary)
                Text(a.answer).font(.system(size: 19, design: .serif))
            }
        }
        if runner.usage != nil || runner.error != nil || runner.hasText {
            Card {
                Label("AI 点评", systemImage: "sparkles").font(.headline)
                StreamStatusView(runner: runner)
                StreamTextView(runner: runner, transform: GradingVerdict.displayText)
            }
        }
        Card {
            Text("参考译文").font(.headline)
            Text(question.reference).font(.system(size: 19, design: .serif)).textSelection(.enabled)
            Divider()
            Text("出处：\(entry.english)").font(.system(.callout, design: .serif)).foregroundStyle(.secondary)
            if let note = entry.note { Text(note).font(.callout).foregroundStyle(.secondary) }
        }
        ratingButtons(a)
    }

    /// 自评；按 AI 结论和是否看了提示，把建议的一档标成实心
    private func ratingButtons(_ a: ExpressionAttempt) -> some View {
        let suggested: FSRSRating? = switch a.verdict {
        case "correct": a.usedHint ? .hard : .good
        case "wrong": .hard
        case "missing": .again
        default: a.answer.isEmpty && a.inkImages.isEmpty ? .again : nil
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("这个表达掌握得怎么样？").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach([(FSRSRating.again, "没想起来", Color.red), (.hard, "想起来但吃力", .orange),
                         (.good, "用对了", .green), (.easy, "很轻松", .blue)], id: \.0) { rating, title, color in
                    Button {
                        rate(a, rating)
                    } label: {
                        Text(title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(suggested == nil || suggested == rating ? color : color.opacity(0.35))
                    .controlSize(.large)
                    .draftTappable()
                }
            }
        }
    }

    private func submit(skipped: Bool) {
        let text = skipped ? "" : typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = skipped ? [] : ReadingPracticeCard.handwritingImages(LiveDraft.drawing(draftKey), frames: areaFrames)
        let a = ExpressionAttempt(entryKey: entry.key, chinese: question.chinese, reference: question.reference,
                                  usedHint: showHint, answer: text, inkImages: images)
        PendingAnswers.remove(key: pendingKey)
        context.insert(a)
        try? context.save()
        attempt = a
        guard !skipped, !text.isEmpty || !images.isEmpty, LLMConfig.hasAvailableProvider(.readingPractice) else {
            if skipped { a.verdict = "missing" }
            return
        }
        let user = ReadingPracticePrompts.expressionReviewUser(
            expression: entry.expression, chinese: question.chinese, reference: question.reference,
            usedHint: showHint, typed: text, imageCount: images.count)
        struct Verdict: Decodable { let expression: String }
        runner.run(system: ReadingPracticePrompts.expressionReviewSystem,
                   messages: [ChatTurn(role: .user, text: user, images: images)],
                   config: .current(.readingPractice),
                   onUpdate: { [runner] text in
                       a.feedback = text
                       a.feedbackIncomplete = true
                       a.usage = runner.usage
                       try? context.save()
                   },
                   onFinish: { [runner] text in
                       a.feedback = text
                       a.feedbackIncomplete = false
                       a.usage = runner.usage
                       a.verdict = TrailingJSON.decode(Verdict.self, from: text)?.expression
                       try? context.save()
                   })
    }

    private func rate(_ a: ExpressionAttempt, _ rating: FSRSRating) {
        runner.cancel()
        entry.rate(rating, retention: ReviewScheduler.retention)
        a.rating = rating.rawValue
        try? context.save()
        onNext()
    }
}

/// 表达本：按加入时间倒序，可以删除
struct ExpressionListView: View {
    @Environment(\.modelContext) private var context
    @Environment(PackStore.self) private var store
    @Query(sort: \ExpressionEntry.createdAt, order: .reverse) private var entries: [ExpressionEntry]

    var body: some View {
        List {
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.expression).font(.system(.headline, design: .serif))
                        Spacer()
                        Text(e.isNew ? "未复习" : "下次 \(e.dueAt.formatted(.dateTime.month().day()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = e.note { Text(note).font(.callout) }
                    Text(e.english).font(.system(.callout, design: .serif)).foregroundStyle(.secondary)
                    if let pack = store.pack(e.packID), let passage = pack.chunks[e.passageID] {
                        let chapter = pack.lectureLocation(ofChunk: e.passageID)?.section.section.chapter
                        Text([pack.title, chapter, passage.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                for i in offsets { context.delete(entries[i]) }
                try? context.save()
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("表达本是空的", systemImage: "text.book.closed",
                                       description: Text("回译时原句里没写出来或写错的重点表达会自动加进来。"))
            }
        }
        .navigationTitle("表达本（\(entries.count)）")
        .navigationBarTitleDisplayMode(.inline)
    }
}
