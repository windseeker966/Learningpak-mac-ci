import SwiftData
import SwiftUI

/// 背说法卡：先看说法，说出它指的是什么，再翻面对照（背面列出易混的说法）、自评。
/// 自评「重来」的卡在本次结束前再出现一次；背完自动关闭
struct PhraseReviewSession: View {
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(PackStore.self) private var store
    @State private var queue: [PhraseCard]
    @State private var index = 0
    @State private var revealed = false

    init(cards: [PhraseCard], onClose: @escaping () -> Void) {
        _queue = State(initialValue: cards)
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if index < queue.count {
                    let c = queue[index]
                    ProgressView(value: Double(index), total: Double(queue.count))
                    ScrollView { card(c) }
                    if revealed {
                        ratingButtons(c)
                    } else {
                        Button {
                            revealed = true
                        } label: {
                            Text("翻面").frame(maxWidth: .infinity)
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
            .navigationTitle(index < queue.count ? "说法卡 \(index + 1) / \(queue.count)" : "说法卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成", action: onClose)
                }
            }
        }
    }

    private func card(_ c: PhraseCard) -> some View {
        let pack = store.pack(c.packID)
        let phrase = pack?.phrases[c.phraseID]
        return VStack(alignment: .leading, spacing: 18) {
            HStack {
                tag(c)
                Spacer()
                if let pack {
                    Text(pack.questions(withPhrase: c.phraseID).map(\.id).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            PhraseText(phrase?.cue ?? c.phraseID)
                .font(.system(size: 26, design: .serif))
                .lineSpacing(8)
            if revealed {
                Divider()
                Text(phrase?.answer ?? "（教辅包里找不到这张卡）")
                    .font(.system(.title, design: .serif).bold())
                if let pack {
                    let others = pack.confusablePhrases(of: c.phraseID)
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("别和这些混", systemImage: "exclamationmark.triangle")
                                .font(.callout.bold()).foregroundStyle(.orange)
                            ForEach(others) { p in
                                (PhraseText.text(p.cue) + Text(" → ") + Text(p.answer).bold())
                                    .font(.callout)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            } else {
                Text("先说出它指的是什么，再翻面。").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    private func tag(_ c: PhraseCard) -> some View {
        let (title, color): (String, Color) = c.isNew ? ("新卡", .blue)
            : c.seededAgain && c.ratings.count == 1 ? ("原题选错过", .red)
            : c.ratings.last == FSRSRating.again.rawValue ? ("重来", .red) : ("复习", .orange)
        return Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private func ratingButtons(_ c: PhraseCard) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach([(FSRSRating.again, "重来", Color.red), (.hard, "模糊", .orange),
                         (.good, "记得", .green), (.easy, "太简单", .blue)], id: \.0) { rating, title, color in
                    Button {
                        rate(c, rating)
                    } label: {
                        Text(title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(color)
                    .controlSize(.large)
                }
            }
            Text("说对而且没犹豫算「记得」；犹豫过、在两个之间挑的算「模糊」；说错或说不出算「重来」。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rate(_ c: PhraseCard, _ rating: FSRSRating) {
        PhraseDeck.rate(c, rating, in: context)
        // 重来的卡放到队尾，本次再背一遍
        if rating == .again { queue.append(c) }
        revealed = false
        index += 1
    }
}

/// 说法：关键词按 **加粗** 显示
struct PhraseText: View {
    let cue: String
    init(_ cue: String) { self.cue = cue }

    var body: some View { Self.text(cue) }

    static func text(_ cue: String) -> Text {
        let s = (try? AttributedString(markdown: cue, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(cue)
        return Text(s)
    }
}

/// 全部说法卡：按书、节列出，放进来的显示下次复习的日期，没放进来的显示「未放」
struct PhraseListView: View {
    @Environment(\.modelContext) private var context
    @Environment(PackStore.self) private var store
    @State private var cards: [String: PhraseCard] = [:]

    var body: some View {
        List {
            ForEach(store.packs.filter { !$0.phrases.isEmpty }) { pack in
                ForEach(pack.sections.filter { !($0.phrases ?? []).isEmpty }, id: \.section.id) { s in
                    Section {
                        ForEach(s.phrases ?? []) { p in row(pack, p) }
                    } header: {
                        Text("\(pack.title) · \(s.section.id) \(s.section.title)").textCase(nil)
                    }
                }
            }
        }
        .onAppear {
            cards = Dictionary(PhraseDeck.all(in: context).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
        .navigationTitle("说法卡（已放 \(cards.count)）")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ pack: StudyPack, _ p: Phrase) -> some View {
        let c = cards[PhraseCard.key(packID: pack.id, phraseID: p.id)]
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                PhraseText(p.cue)
                Text(p.answer).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(c == nil ? "未放" : c!.isNew ? "未背" : "下次 \(c!.dueAt.formatted(.dateTime.month().day()))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
