import SwiftData
import SwiftUI

/// 生词本的 AI 短文复习：读 AI 用背过的词写的短文，在下面写出标黄的词在文中的意思；
/// AI 批改后按结论标出每个词建议的自评，可以改，确认后计入复习（流程见 VocabPassageSession）
struct VocabPassageReviewView: View {
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var session = VocabPassageSession()
    @FocusState private var focused: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AI 短文复习" + (session.finishedCount > 0 ? " · 已做 \(session.finishedCount) 篇" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成", action: onClose)
                }
            }
        }
        .onAppear { session.start(in: context) }
        .onDisappear { session.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if session.notEnoughWords {
            Card {
                Label("没有可以挑的词了", systemImage: "clock").font(.headline)
                Text("一小时内 AI 短文里挑过的词不再挑，剩下背过的词不到 \(Vocab.passageMinimum) 个。过一会儿再来，或先去背新词。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("完成", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
        } else if let passage = session.passage {
            passageCard(passage)
            answerCard(passage)
            footer
        } else if let error = session.error {
            Card {
                Label("短文生成失败", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                Text(error).font(.callout).foregroundStyle(.secondary)
                AIRetryButtons { session.generate(useBackup: $0) }
            }
        } else {
            Card {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("AI 正在用 \(session.words.count) 个背过的词写一篇短文…").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 短文

    private func passageCard(_ passage: VocabPassage) -> some View {
        Card {
            if !passage.title.isEmpty {
                Text(passage.title).font(.system(.title2, design: .serif).bold())
            }
            if session.phase == .answering {
                Text(attributed(passage))
                    .font(.system(size: 21, design: .serif))
                    .lineSpacing(9)
                Text("写出标黄的词在这篇短文里的意思。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                // 提交后可以划词：AI 翻译、加入生词本
                VocabPassageText(passage: passage, passageID: session.passageID, grades: session.grades)
                Text("划选单词或句子可以「AI 翻译」「加入生词本」。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// 生词标黄加粗、后面跟上标的序号；批改后按结论换成绿、橙、红
    private func attributed(_ passage: VocabPassage) -> AttributedString {
        var result = AttributedString()
        for segment in passage.segments {
            switch segment {
            case .text(let s):
                result += AttributedString(s)
            case .word(let id, let surface):
                var word = AttributedString(surface)
                word.backgroundColor = color(session.grades[id]?.result).opacity(0.3)
                word.inlinePresentationIntent = .stronglyEmphasized
                var number = AttributedString("\(passage.number(of: id))")
                number.font = .system(size: 12, weight: .semibold)
                number.baselineOffset = 9
                number.foregroundColor = .secondary
                result += word + number
            }
        }
        return result
    }

    private func color(_ result: VocabPassageResult?) -> Color {
        switch result {
        case .correct: .green
        case .partial: .orange
        case .wrong: .red
        case nil: .yellow
        }
    }

    // MARK: - 作答与批改

    private func answerCard(_ passage: VocabPassage) -> some View {
        Card {
            ForEach(passage.usedIDs, id: \.self) { id in
                if let entry = session.entry(id) {
                    if id != passage.usedIDs.first { Divider() }
                    row(id: id, number: passage.number(of: id), surface: passage.surface(of: id) ?? entry.word, entry: entry, next: next(after: id, in: passage))
                }
            }
        }
    }

    private func next(after id: Int, in passage: VocabPassage) -> Int? {
        guard let i = passage.usedIDs.firstIndex(of: id), i + 1 < passage.usedIDs.count else { return nil }
        return passage.usedIDs[i + 1]
    }

    @ViewBuilder
    private func row(id: Int, number: Int, surface: String, entry: VocabEntry, next: Int?) -> some View {
        let answering = session.phase == .answering
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)").font(.callout.monospacedDigit().bold()).foregroundStyle(.secondary).frame(width: 24)
                Text(surface).font(.system(.title3, design: .serif).bold()).frame(minWidth: 120, alignment: .leading)
                if answering {
                    TextField("在文中的意思", text: Binding(get: { session.answers[id, default: ""] },
                                                       set: { session.answers[id] = $0 }))
                        .font(.title3)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($focused, equals: id)
                        .submitLabel(next == nil ? .done : .next)
                        .onSubmit { focused = next }
                } else {
                    let answer = session.answers[id, default: ""].trimmingCharacters(in: .whitespaces)
                    Text(answer.isEmpty ? "（没写）" : answer)
                        .font(.title3)
                        .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                    Spacer()
                    if let grade = session.grades[id] { verdictLabel(grade.result) }
                }
            }
            if !answering && session.phase != .grading {
                VStack(alignment: .leading, spacing: 8) {
                    if let note = session.grades[id]?.note {
                        Text(note).font(.callout)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("生词本：\(entry.word)").font(.callout.bold())
                        if let phonetic = entry.phonetic { Text(phonetic).font(.callout).foregroundStyle(.secondary) }
                        Button("朗读", systemImage: "speaker.wave.2") { Speech.speak(entry.word) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        Text(entry.meaning ?? "（没有释义）").font(.callout).foregroundStyle(.secondary)
                    }
                    if session.phase == .rating {
                        Picker("自评", selection: Binding(get: { session.ratings[id] }, set: { session.ratings[id] = $0 })) {
                            ForEach([(FSRSRating.again, "不认识"), (.hard, "模糊"), (.good, "认识"), (.easy, "太简单")], id: \.0) {
                                Text($0.1).tag(Optional($0.0))
                            }
                        }
                        .pickerStyle(.segmented)
                    } else if let rating = session.ratings[id] {
                        Text("已计入复习：\(ratingTitle(rating))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 4)
    }

    private func verdictLabel(_ result: VocabPassageResult) -> some View {
        let (title, icon): (String, String) = switch result {
        case .correct: ("对", "checkmark.circle.fill")
        case .partial: ("部分对", "circle.lefthalf.filled")
        case .wrong: ("错", "xmark.circle.fill")
        }
        return Label(title, systemImage: icon).font(.callout.bold()).foregroundStyle(color(result))
    }

    private func ratingTitle(_ rating: FSRSRating) -> String {
        switch rating {
        case .again: "不认识"
        case .hard: "模糊"
        case .good: "认识"
        case .easy: "太简单"
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch session.phase {
        case .generating:
            EmptyView()
        case .answering:
            Button {
                focused = nil
                session.submit()
            } label: {
                Label("提交，请 AI 批改", systemImage: "paperplane").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .grading:
            HStack(spacing: 10) {
                ProgressView()
                Text("AI 正在批改…").foregroundStyle(.secondary)
            }
        case .rating:
            VStack(alignment: .leading, spacing: 12) {
                if let error = session.error {
                    Card {
                        Label("批改失败", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Text("可以重试，或对照生词本的释义自己选每个词的自评。").font(.callout).foregroundStyle(.secondary)
                        AIRetryButtons { session.submit(useBackup: $0) }
                    }
                } else {
                    Text("按 AI 的结论选好了建议的自评（对 → 认识，部分对 → 模糊，错 → 不认识），可以改。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button {
                    session.confirm()
                } label: {
                    Label("确认，计入复习", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!session.canConfirm)
            }
        case .confirmed:
            HStack(spacing: 12) {
                Button {
                    session.next()
                } label: {
                    Label("再来一篇", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onClose) {
                    Text("完成").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }
}

/// 提交后的短文：可以划选，菜单里有「AI 翻译」「加入生词本」（和阅读文章一样弹出 WordPopover）。
/// 考的词按批改结论标色、带序号；在这篇短文里加入生词本的词标黄
private struct VocabPassageText: View {
    let passage: VocabPassage
    let passageID: String
    let grades: [Int: (result: VocabPassageResult, note: String?)]

    @Environment(\.modelContext) private var context
    @Query private var entries: [VocabEntry]

    init(passage: VocabPassage, passageID: String, grades: [Int: (result: VocabPassageResult, note: String?)]) {
        self.passage = passage
        self.passageID = passageID
        self.grades = grades
        let packID = VocabEntry.aiPassagePackID
        _entries = Query(filter: #Predicate<VocabEntry> { $0.packID == packID && $0.passageID == passageID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(passage.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                let hash = VocabSelection.stableHash(paragraph.text)
                PassageParagraphText(
                    text: paragraph.text, fontSize: 21,
                    highlights: entries.filter { $0.paragraph == hash }.map(\.range),
                    marks: paragraph.words.map { ($0.range, color(grades[$0.id]?.result)) },
                    superscripts: paragraph.words.map { ($0.range.location + $0.range.length, "\(passage.number(of: $0.id))") }
                ) { action, range in
                    // 悬浮窗是新的 SwiftUI 根，要把数据库带过去
                    AnyView(WordPopover(selection: VocabSelection(aiPassageID: passageID, title: passage.title,
                                                                  paragraphText: paragraph.text, range: range),
                                        action: action)
                        .modelContainer(context.container))
                }
            }
        }
    }

    private func color(_ result: VocabPassageResult?) -> UIColor {
        let base: UIColor = switch result {
        case .correct: .systemGreen
        case .partial: .systemOrange
        case .wrong: .systemRed
        case nil: .systemYellow
        }
        return base.withAlphaComponent(0.3)
    }
}
