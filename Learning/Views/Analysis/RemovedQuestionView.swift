import SwiftData
import SwiftUI

/// 作答时保存的题目快照（Grader.snapshot / SubjectiveRecords.snapshot 的 JSON）。题目从教辅包移除后用它显示
nonisolated struct QuestionSnapshot {
    let dict: [String: Any]

    init?(_ data: Data) {
        guard let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        dict = d
    }

    var stem: String? { dict["stem"] as? String }

    /// 题面、选项、答案与解析（Markdown）
    var markdown: String {
        var blocks: [String] = []
        if let stem { blocks.append(stem) } else if dict["question_image"] != nil { blocks.append("（题面是原书图片）") }
        // 附图用占位行引用，MarkdownView 按教辅包显示
        for id in dict["figures"] as? [String] ?? [] { blocks.append("[[图 \(id)]]") }
        if let statements = dict["statements"] as? [String: [String: Any]] {
            for k in statements.keys.sorted(by: { Roman.order($0) < Roman.order($1) }) {
                blocks.append("\(Roman.glyph(k)). \(statements[k]?["text"] as? String ?? "")")
            }
        }
        for key in ["options", "shared_options"] {
            if let options = dict[key] as? [String: String] {
                for k in options.keys.sorted() { blocks.append("\(k). \(options[k] ?? "")") }
            } else if let options = dict[key] as? [String: [String]] {
                for k in options.keys.sorted() { blocks.append("\(k). " + (options[k] ?? []).map(Roman.glyph).joined(separator: "、")) }
            }
        }
        if let blanks = dict["blanks"] as? [String] {
            blocks.append("**答案**：" + blanks.joined(separator: "、"))
        } else if let answer = dict["answer"] as? String {
            blocks.append("**答案**：" + answer)
        }
        if let parts = dict["parts"] as? [[String: Any]] {
            for p in parts {
                var text = "**\(p["label"] as? String ?? "")**"
                if let a = p["answer"] as? String { text += " " + a }
                if let points = p["points"] as? [String], !points.isEmpty { text += "\n\n得分点：" + points.joined(separator: "；") }
                blocks.append(text)
            }
        }
        if let e = dict["explanation"] as? String { blocks.append("**解析**：" + e) }
        return blocks.joined(separator: "\n\n")
    }
}

/// 已从教辅包移除的错题：作答时保存的题目和以往每次作答
struct RemovedQuestionView: View {
    let pack: StudyPack
    let questionID: String
    /// 新 → 旧
    let choice: [AttemptRecord]
    let subjective: [SubjectiveAttempt]

    private var snapshot: QuestionSnapshot? {
        (choice.first?.questionSnapshot ?? subjective.first?.questionSnapshot).flatMap(QuestionSnapshot.init)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Card {
                    Text("这道题已从教辅包移除，下面是最近一次作答时保存的题目。").font(.caption).foregroundStyle(.secondary)
                    if let snapshot {
                        MarkdownView(text: snapshot.markdown, pack: pack)
                    } else {
                        Text("没有保存题目内容。").foregroundStyle(.secondary)
                    }
                }
                Card {
                    Text("以往作答").font(.headline)
                    ForEach(Array(choice.enumerated()), id: \.element.persistentModelID) { i, a in
                        if i > 0 { Divider() }
                        choiceRow(a)
                    }
                    ForEach(Array(subjective.enumerated()), id: \.element.persistentModelID) { i, a in
                        if i > 0 { Divider() }
                        subjectiveRow(a)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("已移除的题")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                QuestionMarkControls(packID: pack.id, questionID: questionID)
            }
        }
    }

    private func choiceRow(_ a: AttemptRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: a.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(a.isCorrect ? .green : .red)
                Text("\(a.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(AttemptMode.label(of: a.mode)) · 选 \(a.selection.replacingOccurrences(of: ",", with: "、")) · \(confidenceLabel(a.confidence))")
            }
            if let line = a.causeLine(pack.pointTitle) {
                Text((a.isCorrect ? "没把握：" : "错因：") + line).font(.callout).foregroundStyle(.secondary)
            }
            if !a.isCorrect && !a.weakPoints.isEmpty {
                Text("暴露：" + a.weakPoints.map(pack.pointTitle).joined(separator: "、"))
                    .font(.callout).foregroundStyle(.orange)
            }
            QuestionCard.attemptExtras(a, pack: pack)
        }
    }

    private func subjectiveRow(_ a: SubjectiveAttempt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let r = a.resultValue {
                    Image(systemName: SubjectiveCard.icon(r)).foregroundStyle(SubjectiveCard.color(r))
                }
                Text("\((a.revealedAt ?? a.createdAt).formatted(date: .abbreviated, time: .shortened)) · \(AttemptMode.label(of: a.mode)) · \(a.resultValue?.label ?? "未自评")")
            }
            Text(SubjectiveCard.detailLine(a)).font(.caption).foregroundStyle(.secondary)
            ForEach(a.causeLines(pack.pointTitle), id: \.self) { Text($0).font(.caption) }
            if let note = a.correctionNote, !note.isEmpty {
                Label(note, systemImage: "square.and.pencil").font(.callout)
            }
            CorrectionHistoryView(entries: a.correctionHistory)
            if let data = a.reviewConversationData,
               let conversation = try? JSONDecoder().decode(SavedConversation.self, from: data) {
                DisclosureGroup("AI 讲评") {
                    SavedChatThreadView(conversation: conversation, pack: pack).padding(.top, 8)
                }
                .draftTappable()
            }
            if a.inkData != nil || !a.gradings.isEmpty {
                DisclosureGroup("查看当时的笔迹和 AI 批改") {
                    AttemptInkView(attempt: a, pack: pack).padding(.top, 8)
                }
                .draftTappable()
            }
        }
    }
}
