import SwiftData
import SwiftUI

/// 原题的 AI 改编题记录（新的在前）：题目、作答、错因、订正笔记、讲评，主观题还有笔迹和 AI 批改；可以标记题目有错
struct VariantHistoryCard: View {
    let pack: StudyPack
    @Query private var variants: [VariantAttempt]

    init(pack: StudyPack, originalID: String) {
        self.pack = pack
        let packID = pack.id
        _variants = Query(filter: #Predicate<VariantAttempt> { $0.packID == packID && $0.originalID == originalID },
                          sort: \.createdAt, order: .reverse)
    }

    var body: some View {
        if !variants.isEmpty {
            Card {
                Text("AI 改编题").font(.headline)
                Text("改编题的结果按原题的规则计入复习安排和知识点掌握度；答错算原题没掌握，答对只能把「待巩固」升为「已订正」。学习页的改编练习不计入。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(variants.enumerated()), id: \.element.persistentModelID) { i, v in
                    if i > 0 { Divider() }
                    row(v)
                }
            }
        }
    }

    private func row(_ v: VariantAttempt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let r = v.resultValue {
                    Image(systemName: SubjectiveCard.icon(r)).foregroundStyle(SubjectiveCard.color(r))
                }
                Text(Self.summary(v))
                if v.practice || v.isRedo {
                    Text(v.modeLabel).font(.caption).foregroundStyle(.secondary)
                }
                if v.isAssessed && v.isImmediate {
                    Text("看原题答案后不久做的").font(.caption).foregroundStyle(.secondary)
                }
            }
            if v.kind == "subjective", v.partLabels.count > 1 {
                Text(zip(v.partLabels, v.parts).map { "\($0) \($1.label)" }.joined(separator: "，"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(v.causeLines(pack.pointTitle), id: \.self) { Text((v.isCorrect ? "没把握：" : "错因：") + $0).font(.callout).foregroundStyle(.secondary) }
            if !v.isCorrect && !v.weakPoints.isEmpty {
                Text("暴露：" + v.weakPoints.map(pack.pointTitle).joined(separator: "、"))
                    .font(.callout).foregroundStyle(.orange)
            }
            if let note = v.correctionNote, !note.isEmpty {
                Label(note, systemImage: "square.and.pencil").font(.callout)
            }
            CorrectionHistoryView(entries: v.correctionHistory)
            if let snapshot = v.content.flatMap(QuestionSnapshot.init) {
                DisclosureGroup("改编题题目与答案") {
                    MarkdownView(text: snapshot.markdown, pack: pack).padding(.top, 8)
                }
                .draftTappable()
            }
            if let data = v.reviewConversationData,
               let saved = try? JSONDecoder().decode(SavedConversation.self, from: data) {
                DisclosureGroup("AI 讲评") {
                    SavedChatThreadView(conversation: saved, pack: pack).padding(.top, 8)
                }
                .draftTappable()
            }
            if v.inkData != nil || v.pastedImagesData != nil || v.gradingHistoryData != nil {
                DisclosureGroup("查看当时的笔迹和 AI 批改") {
                    AttemptInkView(attempt: v, pack: pack).padding(.top, 8)
                }
                .draftTappable()
            }
            if let id = v.variantID {
                QuestionFaultBanner(packID: v.packID, questionID: id, variant: true)
                HStack {
                    Spacer()
                    VariantRatingButtons(packID: v.packID, questionID: id, originalID: v.originalID)
                }
            }
        }
    }

    /// 「10月3日 09:00 · 选 B · 错误 · 犹豫」
    static func summary(_ v: VariantAttempt) -> String {
        var items = [v.answeredAt.formatted(date: .abbreviated, time: .shortened)]
        if let s = v.selection { items.append("选 \(s.replacingOccurrences(of: ",", with: "、"))") }
        items.append(v.kind == "choice" ? (v.isCorrect ? "正确" : "错误")
                     : (v.resultValue?.label ?? (v.revealedAt == nil ? "未完成" : "未自评")))
        let c = v.kind == "choice" ? confidenceLabel(v.confidence)
            : (SubjectiveConfidence(rawValue: v.confidence)?.label ?? "")
        if !c.isEmpty { items.append(c) }
        return items.joined(separator: " · ")
    }
}

/// 学习页改编练习保存下来的题目（新的在前）：只有题目和答案，可以删除
struct SavedVariantsCard: View {
    let pack: StudyPack
    @Environment(\.modelContext) private var context
    @Query private var saved: [SavedVariant]

    init(pack: StudyPack, originalID: String) {
        self.pack = pack
        let packID = pack.id
        _saved = Query(filter: #Predicate<SavedVariant> { $0.packID == packID && $0.originalID == originalID },
                       sort: \.createdAt, order: .reverse)
    }

    var body: some View {
        if !saved.isEmpty {
            Card {
                Text("AI 改编练习（\(saved.count)）").font(.headline)
                Text("在学习页改编出的题，只保存题目和答案，不记作答、不参与统计和复习安排。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(saved.enumerated()), id: \.element.persistentModelID) { i, v in
                    if i > 0 { Divider() }
                    DisclosureGroup {
                        if let snapshot = v.content.flatMap(QuestionSnapshot.init) {
                            MarkdownView(text: snapshot.markdown, pack: pack).padding(.top, 8)
                        }
                        Button("删除这道改编题", systemImage: "trash", role: .destructive) {
                            context.delete(v)
                            try? context.save()
                        }
                        .font(.caption)
                        .padding(.top, 4)
                        .draftTappable()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.stem).lineLimit(2)
                            Text(v.createdAt.formatted(date: .abbreviated, time: .shortened)
                                 + (v.model.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .draftTappable()
                }
            }
        }
    }
}
