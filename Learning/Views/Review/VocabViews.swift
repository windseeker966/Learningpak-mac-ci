import SwiftData
import SwiftUI

/// 背单词：先看原句里标黄的词，想出它在这句里的意思，再翻面看释义、自评。
/// 自评「不认识」的词在本次结束前再出现一次；背完自动关闭。
struct VocabReviewSession: View {
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var queue: [VocabEntry]
    @State private var index = 0
    @State private var revealed = false
    @State private var confirmRemove = false

    init(entries: [VocabEntry], onClose: @escaping () -> Void) {
        _queue = State(initialValue: entries)
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if index < queue.count {
                    let e = queue[index]
                    ProgressView(value: Double(index), total: Double(queue.count))
                    card(e)
                    Spacer()
                    if revealed {
                        ratingButtons(e)
                    } else {
                        Button {
                            revealed = true
                        } label: {
                            Text("显示释义").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                } else {
                    Color.clear.onAppear(perform: onClose)
                }
            }
            .padding(32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(index < queue.count ? "背单词 \(index + 1) / \(queue.count)" : "背单词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成", action: onClose)
                }
            }
        }
    }

    private func card(_ e: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(e.isNew ? "新词" : "复习")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((e.isNew ? Color.blue : Color.orange).opacity(0.12), in: Capsule())
                    .foregroundStyle(e.isNew ? .blue : .orange)
                Spacer()
                Button("朗读句子", systemImage: "speaker.wave.2") { Speech.speak(e.sentence) }
                    .buttonStyle(.borderless)
                Button("移出生词本", systemImage: "trash", role: .destructive) { confirmRemove = true }
                    .buttonStyle(.borderless)
                    .confirmationDialog("把「\(e.word)」移出生词本？", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("移出生词本", role: .destructive) { remove(e) }
                    } message: {
                        Text("背单词的记录一并删除。")
                    }
            }
            highlightedSentence(e)
                .font(.system(size: 22, design: .serif))
                .lineSpacing(8)
            if revealed {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(e.word).font(.system(.title2, design: .serif).bold())
                    if let phonetic = e.phonetic { Text(phonetic).font(.title3).foregroundStyle(.secondary) }
                    Button("朗读", systemImage: "speaker.wave.2.fill") { Speech.speak(e.word) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                if e.meaning != nil {
                    MeaningView(meaning: e.storedMeaning)
                        .font(.title3)
                } else {
                    Text("还没有释义（AI 释义生成失败或未配置模型）").foregroundStyle(.secondary)
                    Button("重新生成释义") { Vocab.fillMeaning(e, in: context) }
                }
            } else {
                Text("标黄的词在这句里是什么意思？").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    /// 原句，生词标黄加粗；句子里找不到原词时整句照常显示
    private func highlightedSentence(_ e: VocabEntry) -> Text {
        var s = AttributedString(e.sentence)
        if let r = s.range(of: e.word) {
            s[r].backgroundColor = .yellow.opacity(0.45)
            s[r].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(s)
    }

    private func ratingButtons(_ e: VocabEntry) -> some View {
        HStack(spacing: 12) {
            ForEach([(FSRSRating.again, "不认识", Color.red), (.hard, "模糊", .orange),
                     (.good, "认识", .green), (.easy, "太简单", .blue)], id: \.0) { rating, title, color in
                Button {
                    rate(e, rating)
                } label: {
                    Text(title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(color)
                .controlSize(.large)
            }
        }
    }

    private func rate(_ e: VocabEntry, _ rating: FSRSRating) {
        e.rate(rating, retention: ReviewScheduler.retention)
        try? context.save()
        // 不认识的词放到队尾，本次再背一遍
        if rating == .again { queue.append(e) }
        revealed = false
        index += 1
    }

    /// 移出生词本：从本次队列里拿掉（含「不认识」后排到队尾的那次），接着背下一个
    private func remove(_ e: VocabEntry) {
        index -= queue[..<index].filter { $0 === e }.count
        queue.removeAll { $0 === e }
        revealed = false
        Vocab.remove(e, in: context)
    }
}

/// 生词本：按加入时间倒序列出，可以朗读、删除
struct VocabListView: View {
    @Environment(\.modelContext) private var context
    @Environment(PackStore.self) private var store
    @Query(sort: \VocabEntry.createdAt, order: .reverse) private var entries: [VocabEntry]

    var body: some View {
        List {
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.word).font(.system(.headline, design: .serif))
                        if let phonetic = e.phonetic { Text(phonetic).font(.callout).foregroundStyle(.secondary) }
                        Button("朗读", systemImage: "speaker.wave.2") { Speech.speak(e.word) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        Text(e.meaning ?? "（没有释义）").font(.callout)
                            .foregroundStyle(e.meaning == nil ? .secondary : .primary)
                        Spacer()
                        Text(e.isNew ? "未背" : "下次 \(e.dueAt.formatted(.dateTime.month().day()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(e.sentence).font(.system(.callout, design: .serif)).foregroundStyle(.secondary)
                    if e.isWeb {
                        Text([e.sourceTitle, URL(string: e.passageID)?.host()].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else if e.isImported {
                        Text(["导入", e.sourceTitle].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else if let pack = store.pack(e.packID), let passage = pack.chunks[e.passageID] {
                        let chapter = pack.lectureLocation(ofChunk: e.passageID)?.section.section.chapter
                        Text([pack.title, chapter, passage.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary)
                    } else if let title = e.sourceTitle {
                        // 其他程序收集、用 import_vocab.sh 导入的（如 FTL 划词翻译）
                        Text(title).font(.caption2).foregroundStyle(.tertiary)
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
                ContentUnavailableView("生词本是空的", systemImage: "character.book.closed",
                                       description: Text("做阅读题或在浏览器里看网页时，划选单词，选「加入生词本」。"))
            }
        }
        .navigationTitle("生词本（\(entries.count)）")
        .navigationBarTitleDisplayMode(.inline)
    }
}
