import PencilKit
import SwiftData
import SwiftUI

extension CorrectionStatus {
    var color: Color {
        switch self {
        case .unresolved: .red
        case .consolidating: .orange
        case .resolved, .markedMastered: .green
        }
    }
}

/// 「标记题目有错…」：原题和 AI 改编题共用，按题目 id 记在 QuestionMark。从第一次碰到这道题起就能标记，可以随时取消。
/// 原题标记后复习、错题本和统计都不再使用它；改编题叫「出得不好…」，标记后这道改编题的作答都不计入原题，并告诉下次改编避开
struct QuestionFaultButton: View {
    let packID: String
    let questionID: String
    /// 改编题的原题 id；nil 表示是原题
    var originalID: String? = nil

    @Environment(\.modelContext) private var context
    @Query private var marks: [QuestionMark]
    @State private var editing = false
    @State private var reasons: Set<FaultReason> = []
    @State private var note = ""

    init(packID: String, questionID: String, originalID: String? = nil) {
        self.packID = packID
        self.questionID = questionID
        self.originalID = originalID
        let key = "\(packID)|\(questionID)"
        _marks = Query(filter: #Predicate<QuestionMark> { $0.key == key })
    }

    private var mark: QuestionMark? { marks.first }
    private var faulty: Bool { mark?.faulty == true }
    private var variant: Bool { originalID != nil }

    var body: some View {
        Button(variant ? (faulty ? "已评价出得不好…" : "出得不好…") : faulty ? "修改有错标记…" : "标记题目有错…",
               systemImage: variant ? (faulty ? "hand.thumbsdown.fill" : "hand.thumbsdown") : "exclamationmark.bubble") {
            note = mark?.faultyNote ?? ""
            reasons = Set((mark?.faultyReasons ?? []).compactMap(FaultReason.init(rawValue:)))
            editing = true
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .foregroundStyle(faulty ? Color.red : .secondary)
        .draftTappable()
        .popover(isPresented: $editing) { editor }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(variant ? (faulty ? "已评价这道改编题出得不好" : "这道改编题出得不好") : faulty ? "已标记这道题有错" : "标记这道题有错").font(.headline)
            Text(variant ? "题目或答案有误、考偏了、太简单或太难时选这个。这道改编题的作答都作废，不计入原题的复习安排和统计；下次改编会避开同样的问题。可以随时取消。"
                 : "题干、选项、答案或解析有误时标记。标记后复习、错题本和统计都不再使用这道题；可以随时取消。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(FaultReason.options(variant: variant), id: \.self) { r in
                    let picked = reasons.contains(r)
                    Button {
                        if picked { reasons.remove(r) } else { reasons.insert(r) }
                    } label: {
                        Label(r.label, systemImage: picked ? "checkmark.square.fill" : "square")
                            .font(.callout)
                            .foregroundStyle(picked ? Color.red : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField(variant ? "具体说明（选填），如：C 也对；第 2 问缺条件" : "哪里有错（选填），如：答案应为 C",
                      text: $note, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                if faulty {
                    Button(variant ? "取消评价" : "取消标记", role: .destructive) { set(false) }
                }
                Spacer()
                Button(faulty ? "保存" : variant ? "出得不好" : "标记有错") { set(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func set(_ on: Bool) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked = FaultReason.allCases.filter(reasons.contains).map(\.rawValue)
        QuestionMark.update(packID: packID, questionID: questionID, scheduleID: originalID, in: context) {
            $0.faultyAt = on ? ($0.faultyAt ?? .now) : nil
            $0.faultyNote = on && !trimmed.isEmpty ? trimmed : nil
            $0.faultyReasons = on ? picked : []
            if on { $0.ratedGoodAt = nil }
        }
        editing = false
    }
}

/// 标题栏右上角的「题目有错」标签：只在标记后出现，和「AI 出题」一样只是标注
struct QuestionFaultBadge: View {
    @Query private var marks: [QuestionMark]

    init(packID: String, questionID: String) {
        let key = "\(packID)|\(questionID)"
        _marks = Query(filter: #Predicate<QuestionMark> { $0.key == key })
    }

    var body: some View {
        if marks.first?.faulty == true {
            Label("题目有错", systemImage: "exclamationmark.triangle.fill").font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red.opacity(0.12), in: Capsule())
                .foregroundStyle(.red)
        }
    }
}

/// 题目卡片底部的工具：AI改编、标记题目有错
struct QuestionToolsRow: View {
    let packID: String
    let questionID: String
    /// nil 时不显示 AI 改编
    var onAIVariant: (() -> Void)?
    var aiAvailable = true
    /// 改编题的原题 id；nil 表示是原题
    var originalID: String? = nil

    var body: some View {
        Divider()
        HStack(spacing: 16) {
            if let onAIVariant {
                Button { onAIVariant() } label: {
                    Label("AI改编", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .disabled(!aiAvailable)
                .draftTappable()
            }
            Spacer()
            if let originalID {
                VariantRatingButtons(packID: packID, questionID: questionID, originalID: originalID)
            } else {
                QuestionFaultButton(packID: packID, questionID: questionID)
            }
        }
    }
}

/// AI 改编题的评价：「出得好」「出得不好…」。出得好：作答照常计入原题，下次改编作为好的例子；
/// 出得不好就是标记有错：这道改编题的作答都作废。没评价的照常计入
struct VariantRatingButtons: View {
    let packID: String
    let questionID: String
    let originalID: String

    @Environment(\.modelContext) private var context
    @Query private var marks: [QuestionMark]

    init(packID: String, questionID: String, originalID: String) {
        self.packID = packID
        self.questionID = questionID
        self.originalID = originalID
        let key = "\(packID)|\(questionID)"
        _marks = Query(filter: #Predicate<QuestionMark> { $0.key == key })
    }

    private var good: Bool { marks.first?.ratedGood == true }

    var body: some View {
        HStack(spacing: 16) {
            Button(good ? "已评价出得好" : "出得好", systemImage: good ? "hand.thumbsup.fill" : "hand.thumbsup") {
                let on = !good
                QuestionMark.update(packID: packID, questionID: questionID, scheduleID: originalID, in: context) {
                    $0.ratedGoodAt = on ? .now : nil
                    if on {
                        $0.faultyAt = nil
                        $0.faultyNote = nil
                        $0.faultyReasons = []
                    }
                }
            }
            .font(.callout)
            .buttonStyle(.borderless)
            .foregroundStyle(good ? Color.green : .secondary)
            .draftTappable()
            QuestionFaultButton(packID: packID, questionID: questionID, originalID: originalID)
        }
    }
}

/// 标记了有错的题，在题目下方提示
struct QuestionFaultBanner: View {
    /// 改编题：不计入的是这道改编题的作答
    var variant = false
    @Query private var marks: [QuestionMark]

    init(packID: String, questionID: String, variant: Bool = false) {
        self.variant = variant
        let key = "\(packID)|\(questionID)"
        _marks = Query(filter: #Predicate<QuestionMark> { $0.key == key })
    }

    var body: some View {
        if let mark = marks.first, mark.faulty {
            Label((variant ? "已评价这道改编题出得不好" : "已标记这道题有错") + (mark.faultyDescription.map { "：\($0)" } ?? "")
                  + (variant ? "。这道改编题的作答作废，不计入原题的复习安排和统计。" : "。复习、错题本和统计不再使用这道题。"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

/// 题目上的「重点」「已掌握」开关
struct QuestionMarkControls: View {
    let packID: String
    let questionID: String

    @Environment(\.modelContext) private var context
    @Query private var marks: [QuestionMark]

    init(packID: String, questionID: String) {
        self.packID = packID
        self.questionID = questionID
        let key = "\(packID)|\(questionID)"
        _marks = Query(filter: #Predicate<QuestionMark> { $0.key == key })
    }

    private var mark: QuestionMark? { marks.first }
    private var starred: Bool { mark?.starred == true }
    /// 已掌握的标记早于最近一次答错就不算数
    private var mastered: Bool { WrongBook.isMastered(mark, in: context) }

    var body: some View {
        HStack(spacing: 10) {
            Button(starred ? "已标为重点" : "标为重点", systemImage: starred ? "star.fill" : "star") {
                QuestionMark.update(packID: packID, questionID: questionID, in: context) { $0.starred.toggle() }
            }
            .tint(.yellow)
            .draftTappable()
            Button(mastered ? "已掌握" : "标为已掌握", systemImage: mastered ? "checkmark.seal.fill" : "checkmark.seal") {
                let now = mastered
                QuestionMark.update(packID: packID, questionID: questionID, in: context) {
                    $0.masteredAt = now ? nil : .now
                }
            }
            .tint(.green)
            .help("不用再练这道题；之后再答错会自动取消")
            .draftTappable()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// 订正笔记的手写图片，按书写区顺序竖排
struct CorrectionInkImages: View {
    let images: [Data]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                if let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxWidth: img.size.width / 2, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                }
            }
        }
    }
}

/// 订正笔记以前的版本（改过才显示），新的在前
struct CorrectionHistoryView: View {
    let entries: [CorrectionEntry]

    var body: some View {
        if entries.count > 1 {
            DisclosureGroup("订正笔记改过 \(entries.count - 1) 次") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries.dropLast().reversed().enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(e.note ?? "（清空了笔记）").font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .font(.callout)
            .draftTappable()
        }
    }
}
