import SwiftData
import SwiftUI

/// 一本书的「AI 提问」：以前的对话列表和新对话入口
struct BookChatListView: View {
    let pack: StudyPack

    @Environment(\.modelContext) private var context
    @Query(sort: \BookChat.updatedAt, order: .reverse) private var allChats: [BookChat]

    private var chats: [BookChat] { allChats.filter { $0.packID == pack.id } }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    BookChatView(pack: pack, chat: nil)
                } label: {
                    Label("新对话", systemImage: "plus.bubble").font(.body.bold())
                }
            } footer: {
                Text("AI 知道全书目录和你的进度，需要时会自己查阅某几轮的原文、题目和你的作答；回答里可以带跳到某一轮或某道题的按钮。")
            }
            if !chats.isEmpty {
                Section("以前的对话") {
                    ForEach(chats) { chat in
                        NavigationLink {
                            BookChatView(pack: pack, chat: chat)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title).lineLimit(2)
                                Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { chats[$0] }
                        doomed.forEach(context.delete)
                        try? context.save()
                    }
                }
            }
        }
        .navigationTitle("AI 提问")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一段对话。每次请求前刷新目录和进度；AI 写了查阅命令就自动把那几轮的资料发过去，让它接着回答
struct BookChatView: View {
    let pack: StudyPack

    @Environment(\.modelContext) private var context
    @Environment(\.renderScale) private var renderScale
    /// 新对话第一次保存时才写进数据库，没问过问题的不留记录
    @State private var chat: BookChat
    @State private var session = ChatSession()
    @State private var loaded = false
    @State private var saveError: String?

    init(pack: StudyPack, chat: BookChat?) {
        self.pack = pack
        _chat = State(initialValue: chat ?? BookChat(packID: pack.id, title: "新对话"))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.messages.isEmpty && !session.isBusy { intro }
                    ForEach(Array(session.messages.enumerated()), id: \.offset) { _, m in
                        message(m)
                    }
                    if session.runner.isRunning || session.runner.error != nil {
                        StreamStatusView(runner: session.runner)
                        if !session.runner.text.isEmpty { BookChatAnswerView(text: session.runner.text, pack: pack) }
                    } else if session.canRegenerate {
                        AIRetryButtons(retryLabel: "重新回答", backupLabel: "用备用模型重新回答") { session.regenerate(useBackup: $0) }
                    }
                    if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(24)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                ChatInputView(session: session, placeholder: "比如：我现在该复习什么？列表推导式在哪一轮讲的？")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .onChange(of: session.messages.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("问《\(pack.title)》的任何问题", systemImage: "sparkles").font(.headline)
            Text("AI 每次都能看到全书目录（章、节、每一轮讲什么、有哪些题）和你的进度、错题、复习队列。问到具体内容时，它会先查阅相关几轮的原文和题目再回答。")
            Text("可以问：某个概念在哪一轮讲、这一章我哪里薄弱、某道题为什么选这个、接下来该学什么。回答里的按钮能直接跳到那一轮或那道题。")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func message(_ m: ChatSession.Message) -> some View {
        if m.role == .user {
            if m.auto {
                Label(m.shown, systemImage: "book.pages").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    if let q = m.quote { QuoteChip(quote: q) }
                    MathText.text(m.shown, font: .preferredFont(forTextStyle: .body), scale: renderScale)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            ModelBadge(usage: m.usage)
            if m.incomplete { Text("未完成的回答").font(.caption).foregroundStyle(.secondary) }
            BookChatAnswerView(text: m.text, pack: pack, onSelect: session.handle)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let saved = chat.conversation { session.restore(saved) }
        session.sendPurpose = .bookChat
        let pack = pack, context = context, chat = chat
        session.beforeStream = { [weak session] in
            session?.system = BookChatPrompts.system(pack: pack, progress: BookChatProgress.load(pack: pack, in: context))
        }
        session.followUp = { [weak session] answer in
            guard let session else { return nil }
            // 这次提问（最后一条自己发的消息）之后已经自动查阅了几次
            let used = session.messages.reversed().prefix { $0.role == .assistant || $0.auto }.filter(\.auto).count
            return BookChatPrompts.lookupReply(for: answer, pack: pack,
                                               progress: BookChatProgress.load(pack: pack, in: context), used: used)
        }
        session.onSave = { saved in
            if chat.modelContext == nil { context.insert(chat) }
            if chat.title == "新对话", let first = saved.messages.first(where: { $0.role == "user" && $0.auto != true }) {
                let q = first.shown.trimmingCharacters(in: .whitespacesAndNewlines)
                chat.title = q.count > 40 ? String(q.prefix(40)) + "…" : q
            }
            chat.conversation = saved
            chat.updatedAt = .now
            do {
                try context.save()
                saveError = nil
            } catch {
                saveError = "对话保存失败：\(error.localizedDescription)"
            }
        }
        #if DEBUG
        // 调试：-debugBookChatDump YES 把目录（系统提示）和一次查阅的结果打印到控制台；
        // -debugBookChatAsk "问题" 打开后自动发送（会调用模型）
        let d = UserDefaults.standard
        if d.bool(forKey: "debugBookChatDump") {
            let progress = BookChatProgress.load(pack: pack, in: context)
            let system = BookChatPrompts.system(pack: pack, progress: progress)
            print("[bookchat] system \(system.count) 字\n\(system)")
            if let s = pack.sections.first, s.rounds.count > 1 {
                let reply = BookChatPrompts.lookupReply(for: "[[查阅 \(s.section.id)#2]]\n[[查阅 不存在#9]]",
                                                        pack: pack, progress: progress, used: 0)
                print("[bookchat] lookup shown=\(reply?.shown ?? "nil") \(reply?.text.count ?? 0) 字\n\(reply?.text ?? "")")
            }
        }
        // -debugBookChatAnswer "<markdown>" 用给定文本当作 AI 的回答显示（不调用模型、不保存），检查查阅和跳转标记
        if let fake = d.string(forKey: "debugBookChatAnswer") {
            session.restore(SavedConversation(system: "", context: [], messages: [
                .init(role: "user", text: "（调试）", shown: "（调试）"),
                .init(role: "assistant", text: "[[查阅 3.1#6]]", shown: "[[查阅 3.1#6]]"),
                .init(role: "user", text: "", shown: "已把 3.1 第 6 轮 的原文和题目发给 AI", auto: true),
                .init(role: "assistant", text: fake, shown: fake),
            ], draft: "", partialText: ""))
        }
        if let q = d.string(forKey: "debugBookChatAsk"), session.messages.isEmpty {
            session.send(q)
        }
        #endif
    }
}

/// AI 的回答：查阅命令显示为一行说明，跳转命令显示为按钮，其余按 Markdown 显示
struct BookChatAnswerView: View {
    let text: String
    let pack: StudyPack
    var onSelect: ((SelectionAction) -> Void)? = nil

    private enum Piece {
        case text(String)
        case markers([BookChatMarker])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.pieces(text).enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let s):
                    MarkdownView(text: s, source: "你前面的回答", onSelect: onSelect, pack: pack)
                case .markers(let markers):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                            switch marker {
                            case .lookup(let target):
                                Label("查阅 \(lookupName(target))", systemImage: "book.pages")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .jump(let target):
                                BookChatJumpLink(pack: pack, target: target)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lookupName(_ target: String) -> String {
        guard let ref = BookRef.resolve(target, in: pack) else { return target }
        return "\(ref.section.section.id) \(ref.section.section.title) 第 \(ref.roundIndex + 1) 轮"
    }

    /// 按行拆开：带标记的行拆出标记（行里其余文字留在正文里），代码块里的不算
    private static func pieces(_ text: String) -> [Piece] {
        var out: [Piece] = []
        var buffer: [String] = []
        var inCode = false
        func flush() {
            let s = buffer.joined(separator: "\n")
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(s)) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            let (markers, rest) = inCode ? ([], line) : BookChatMarker.split(line: line)
            if markers.isEmpty {
                buffer.append(line)
                continue
            }
            if !rest.isEmpty { buffer.append(rest) }
            flush()
            out.append(.markers(markers))
        }
        flush()
        return out
    }
}

/// 跳到某一轮的讲解或某道题
struct BookChatJumpLink: View {
    let pack: StudyPack
    let target: String

    var body: some View {
        if let ref = BookRef.resolve(target, in: pack) {
            NavigationLink {
                StudySessionView(pack: pack, section: ref.section, start: ref.start)
            } label: {
                Label(title(ref), systemImage: "arrow.right.circle")
            }
            .buttonStyle(.bordered)
        } else {
            Text("（找不到「\(target)」）").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(_ ref: BookRef) -> String {
        let s = ref.section
        switch ref {
        case .round(_, let i):
            let r = s.rounds[i]
            let topic = r.displayTitle(chunkTitles: r.chunks.compactMap { pack.chunks[$0]?.title })
            return "\(s.section.id) \(s.section.title) · 第 \(i + 1) 轮 · \(topic)"
        case .question(_, let r, let q, let id):
            return "\(s.section.id) \(s.section.title) · 第 \(r + 1) 轮第 \(q + 1) 题（\(id)）"
        }
    }
}
