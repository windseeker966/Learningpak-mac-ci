import PencilKit
import SwiftData
import SwiftUI

/// 阅读轮的读后练习（段落概括、回译），在学习页里和题目排在一起做。
/// 在书写区手写，或用键盘输入（Pencil 也可以直接写进输入框）；提交后把书写区截图和输入的文字交给 AI 点评。
/// 每次提交另存一条记录；「再写一次」清掉本页笔迹重新写。不自评、本身不进复习；
/// 回译原句里没写对的重点表达加入表达本，在复习页换新句子练
struct ReadingPracticeCard: View {
    let pack: StudyPack
    let item: ReadingPracticeItem
    /// 条目 id（ReadingPracticeItem.ids），书写区数量、草稿按它保存
    let itemID: String
    let sectionID: String
    let nextLabel: String
    let onNext: () -> Void

    @Environment(\.modelContext) private var context
    @Query private var summaries: [PassageSummaryAttempt]
    @Query private var translations: [BackTranslationAttempt]
    /// 这句回译加入表达本的表达
    @Query private var expressions: [ExpressionEntry]
    @State private var typed = ""
    @State private var areaFrames: [Int: CGRect] = [:]
    /// 正在看的这次提交；nil 为作答中
    @State private var currentID: PersistentIdentifier?
    @State private var runner = StreamRunner()
    @State private var error: String?
    @State private var loaded = false

    init(pack: StudyPack, item: ReadingPracticeItem, itemID: String, sectionID: String,
         nextLabel: String, onNext: @escaping () -> Void) {
        self.pack = pack
        self.item = item
        self.itemID = itemID
        self.sectionID = sectionID
        self.nextLabel = nextLabel
        self.onNext = onNext
        let packID = pack.id, passageID = item.passage.id
        _summaries = Query(filter: #Predicate<PassageSummaryAttempt> { $0.packID == packID && $0.passageID == passageID },
                           sort: \PassageSummaryAttempt.createdAt, order: .reverse)
        var key = ""
        if case .backTranslation(let passage, _, let drill) = item {
            key = BackTranslationAttempt.key(packID: pack.id, passageID: passage.id, english: drill.en)
        }
        _translations = Query(filter: #Predicate<BackTranslationAttempt> { $0.sentenceKey == key },
                              sort: \BackTranslationAttempt.createdAt, order: .reverse)
        var english = ""
        if case .backTranslation(_, _, let drill) = item { english = drill.en }
        _expressions = Query(filter: #Predicate<ExpressionEntry> {
            $0.packID == packID && $0.passageID == passageID && $0.english == english
        }, sort: \ExpressionEntry.createdAt)
    }

    private var draftKey: String { DraftKey.question(pack: pack.id, questionID: itemID) }
    private var isSummary: Bool { if case .summary = item { true } else { false } }

    /// 以往的提交（新的在前），统一成显示用的形式
    private var records: [Record] {
        isSummary ? summaries.map(Record.init) : translations.map(Record.init)
    }

    private var current: Record? { records.first { $0.id == currentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            promptCard
            if currentID == nil { typedField }
            ChoiceWritingSection(pack: pack, sectionID: sectionID, questionID: itemID, draftKey: draftKey,
                                 accessory: AnyView(actionButtons), initialAreas: isSummary ? 2 : 1,
                                 areaFrames: $areaFrames)
                .id(itemID)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            // 结果放在书写区下方，提交后笔迹不移动，点评就在按钮下面
            if let current { resultCards(current) }
            pastRecords
        }
        .onAppear(perform: load)
        .onDisappear { runner.cancel() }
        .onChange(of: typed) { if currentID == nil { savePending() } }
    }

    // MARK: - 题面

    private var promptCard: some View {
        Card {
            HStack {
                Text(item.label).font(.headline)
                Text(item.passage.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            switch item {
            case .summary(let passage):
                Text("每段用一句英文写出要点，按段编号（1. 2. …，共 \(passage.paragraphs.count) 段），最后写 2–3 句全文概括。抓住每段在全文中的作用，不用照抄原句。")
                    .font(.callout)
            case .backTranslation(_, _, let drill):
                Text(drill.zh).font(.title3).lineSpacing(6).textSelection(.enabled)
                Text("把这句话写成英文。不用追求和原文一模一样，先写出你能写的最好的句子。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var typedField: some View {
        TextField("也可以用键盘输入（手写时留空）", text: $typed, axis: .vertical)
            .lineLimit(isSummary ? 2...10 : 1...5)
            .font(.system(size: 19, design: .serif))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.sentences)
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .draftTappable()
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if currentID == nil {
                Button("提交，请 AI 点评", systemImage: "paperplane") { submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .draftTappable()
            } else {
                Button("再写一次", systemImage: "arrow.counterclockwise") { restart() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(runner.isRunning)
                    .draftTappable()
            }
            Button(nextLabel, action: onNext)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .draftTappable()
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private func resultCards(_ r: Record) -> some View {
        if !r.typed.isEmpty {
            Card {
                Text("键盘输入").font(.caption).foregroundStyle(.secondary)
                Text(r.typed).font(.system(size: 19, design: .serif)).textSelection(.enabled)
            }
        }
        if case .backTranslation(_, _, let drill) = item {
            Card {
                HStack {
                    Text("原句").font(.headline)
                    Spacer()
                    Button("朗读", systemImage: "speaker.wave.2") { Speech.speak(drill.en) }
                        .buttonStyle(.borderless)
                        .draftTappable()
                }
                Text(drill.en).font(.system(size: 20, design: .serif)).lineSpacing(6).textSelection(.enabled)
                if let focus = drill.focus, !focus.isEmpty {
                    Text("值得学的表达：" + focus.joined(separator: "；")).font(.callout).foregroundStyle(.orange)
                }
            }
        }
        Card {
            Label("AI 点评", systemImage: "sparkles").font(.headline)
            if runner.usage != nil || runner.error != nil {
                StreamStatusView(runner: runner)
            } else if let usage = r.usage {
                ModelBadge(usage: usage)
            }
            let text = GradingVerdict.displayText(runner.text.isEmpty ? (r.feedback ?? "") : runner.text)
            if !text.isEmpty {
                MarkdownView(text: text)
            } else if !runner.isRunning && runner.error == nil {
                Text(LLMConfig.hasAvailableProvider(.readingPractice) ? "没有点评。" : "尚未配置模型，请到「设置」中填写。")
                    .foregroundStyle(.secondary)
            }
            if r.feedbackIncomplete && !runner.isRunning && runner.text.isEmpty {
                Text("点评没有生成完").font(.caption).foregroundStyle(.orange)
            }
            if !expressions.isEmpty && !runner.isRunning {
                Label("已加入表达本，在复习页换新句子练：" + expressions.map(\.expression).joined(separator: "；"),
                      systemImage: "text.book.closed")
                    .font(.callout).foregroundStyle(.purple)
            }
        }
        if case .summary(let passage) = item, let reference = passage.summary, !runner.isRunning {
            Card {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(reference.paragraphs.enumerated()), id: \.offset) { i, s in
                            Text("第 \(i + 1) 段：\(s)").font(.system(.callout, design: .serif))
                        }
                        Text("全文：\(reference.whole)").font(.system(.callout, design: .serif))
                    }
                    .padding(.top, 6)
                } label: {
                    Label("参考概括（AI 编写，只是一种写法）", systemImage: "text.book.closed").font(.headline)
                }
                .draftTappable()
            }
        }
    }

    /// 以往的提交（不含正在看的这次）；作答中不显示，免得先看到以前写的
    @ViewBuilder
    private var pastRecords: some View {
        let past = records.filter { $0.id != currentID }
        if currentID != nil, !past.isEmpty {
            Card {
                Text("以往作答（\(past.count)）").font(.headline)
                ForEach(past) { r in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(r.images.enumerated()), id: \.offset) { _, data in
                                if let img = UIImage(data: data) {
                                    Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 820, maxHeight: 400)
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                }
                            }
                            if !r.typed.isEmpty { Text(r.typed).font(.system(.callout, design: .serif)) }
                            if let f = r.feedback, !f.isEmpty {
                                Divider()
                                if r.feedbackIncomplete { Text("点评没有生成完").font(.caption).foregroundStyle(.orange) }
                                MarkdownView(text: GradingVerdict.displayText(f))
                                ModelBadge(usage: r.usage)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                    }
                    .draftTappable()
                }
            }
        }
    }

    // MARK: - 动作

    /// 打开时显示最近一次提交的结果
    private func load() {
        guard !loaded else { return }
        loaded = true
        currentID = records.first?.id
        // 上次没提交的（或点了「再写一次」还没提交的）接着写
        if let p = PendingAnswers.load(PendingAnswers.Reading.self, key: pendingKey),
           records.first.map({ p.savedAt > $0.createdAt }) ?? true {
            currentID = nil
            typed = p.value.typed
        }
    }

    private var pendingKey: String { PendingAnswers.readingKey(pack: pack.id, itemID: itemID) }

    /// 键盘输入随时存下；点了「再写一次」也存一条（内容为空），下次打开时停在作答中，不显示上次的结果
    private func savePending() {
        PendingAnswers.save(PendingAnswers.Reading(typed: typed), key: pendingKey)
    }

    private func submit() {
        error = nil
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = Self.handwritingImages(SubjectiveRecords.pageDrawing(draftKey, in: context), frames: areaFrames)
        guard !text.isEmpty || !images.isEmpty else {
            error = "还没有写内容：在书写区手写，或在输入框里输入。"
            return
        }
        PendingAnswers.remove(key: pendingKey)
        let system: String, user: String
        let onSave: (String, Bool, LLMUsage?) -> Void
        switch item {
        case .summary(let passage):
            let a = PassageSummaryAttempt(packID: pack.id, passageID: passage.id, typedText: text, inkImages: images)
            context.insert(a)
            // 先保存再取 id：保存前是临时 id，保存后会变
            try? context.save()
            currentID = a.persistentModelID
            system = ReadingPracticePrompts.summarySystem
            user = ReadingPracticePrompts.summaryUser(passage: passage, typed: text, imageCount: images.count)
            onSave = { a.feedback = $0; a.feedbackIncomplete = !$1; a.usage = $2 }
        case .backTranslation(let passage, _, let drill):
            let a = BackTranslationAttempt(
                sentenceKey: BackTranslationAttempt.key(packID: pack.id, passageID: passage.id, english: drill.en),
                packID: pack.id, passageID: passage.id, answer: text, inkImages: images)
            context.insert(a)
            try? context.save()
            currentID = a.persistentModelID
            let paragraphs = passage.paragraphs
            let paragraph = paragraphs.indices.contains(drill.paragraph - 1) ? paragraphs[drill.paragraph - 1] : nil
            system = ReadingPracticePrompts.backTranslationSystem
            user = ReadingPracticePrompts.backTranslationUser(drill: drill, typed: text, imageCount: images.count,
                                                              paragraph: paragraph)
            onSave = { [context] text, done, usage in
                a.feedback = text
                a.feedbackIncomplete = !done
                a.usage = usage
                if done {
                    ExpressionBook.addFromBackTranslation(feedback: text, packID: a.packID, passageID: a.passageID,
                                                          drill: drill, in: context)
                }
            }
        }
        guard LLMConfig.hasAvailableProvider(.readingPractice) else { return }
        runner.run(system: system, messages: [ChatTurn(role: .user, text: user, images: images)],
                   config: .current(.readingPractice),
                   onUpdate: { [runner] text in
                       onSave(text, false, runner.usage)
                       try? context.save()
                   },
                   onFinish: { [runner] text in
                       onSave(text, true, runner.usage)
                       try? context.save()
                   })
    }

    /// 再写一次：清掉本页笔迹（已提交的截图存在记录里）
    private func restart() {
        runner.cancel()
        runner = StreamRunner()
        DraftStore.delete(draftKey, reason: "reading_practice_redo", in: context)
        currentID = nil
        typed = ""
        error = nil
        savePending()
    }

    /// 有笔迹的书写区各一张截图，书写区外的笔迹另成一张；没有笔迹时为空
    static func handwritingImages(_ page: PKDrawing?, frames: [Int: CGRect]) -> [Data] {
        guard let page, !page.strokes.isEmpty else { return [] }
        return HandwritingExport.images(page, areas: frames, skipEmptyAreas: true).all
    }

    /// 两种练习记录的共同部分
    private struct Record: Identifiable {
        let id: PersistentIdentifier
        let typed: String
        let images: [Data]
        let feedback: String?
        let feedbackIncomplete: Bool
        let usage: LLMUsage?
        let createdAt: Date

        init(_ a: PassageSummaryAttempt) {
            id = a.persistentModelID
            typed = a.typedText
            images = a.inkImages
            feedback = a.feedback
            feedbackIncomplete = a.feedbackIncomplete
            usage = a.usage
            createdAt = a.createdAt
        }

        init(_ a: BackTranslationAttempt) {
            id = a.persistentModelID
            typed = a.answer
            images = a.inkImages
            feedback = a.feedback
            feedbackIncomplete = a.feedbackIncomplete
            usage = a.usage
            createdAt = a.createdAt
        }
    }
}
