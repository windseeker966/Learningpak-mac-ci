import SwiftUI

/// 对话展示 + 输入框。AI 的回答可以继续划选提问。
struct ChatThreadView: View {
    @Bindable var session: ChatSession
    var placeholder: String
    var showsInput = true
    /// 传入后，回答中的 [[图 id]] 显示为原书图片
    var pack: StudyPack? = nil

    @Environment(\.renderScale) private var renderScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(session.messages.enumerated()), id: \.offset) { _, m in
                if m.role == .user {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let q = m.quote { QuoteChip(quote: q) }
                        MathText.text(m.shown, font: .preferredFont(forTextStyle: .body), scale: renderScale)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ModelBadge(usage: m.usage)
                    if m.incomplete { Text("未完成的回答").font(.caption).foregroundStyle(.secondary) }
                    MarkdownView(text: m.text, source: "你前面的回答", onSelect: session.handle, pack: pack)
                }
            }
            if session.runner.isRunning || session.runner.error != nil {
                // 恢复的对话没有上一次请求可原样再发，按对话内容重新生成
                StreamStatusView(runner: session.runner, onRetry: session.canResume ? { session.resume(useBackup: $0) } : nil)
                StreamTextView(runner: session.runner, pack: pack)
            } else if session.canRegenerate {
                AIRetryButtons(retryLabel: "重新回答", backupLabel: "用备用模型重新回答") { session.regenerate(useBackup: $0) }
            } else if session.canResume {
                // 还没生成出文字就离开了
                Text("上次没有生成完。").font(.callout).foregroundStyle(.secondary)
                AIRetryButtons(retryLabel: "重新生成", backupLabel: "用备用模型重新生成") { session.resume(useBackup: $0) }
            }
            if showsInput {
                ChatInputView(session: session, placeholder: placeholder)
            }
        }
    }
}

/// 输入状态单独观察，键盘输入不重新构建整段公式、讲评和题面。
struct ChatInputView: View {
    @Bindable var session: ChatSession
    let placeholder: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let q = session.pendingQuote {
                HStack(alignment: .top) {
                    QuoteChip(quote: q)
                    Spacer(minLength: 0)
                    Button("取消引用", systemImage: "xmark.circle.fill") { session.pendingQuote = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .draftTappable()
                }
            }
            HStack(alignment: .bottom) {
                TextField(session.pendingQuote == nil ? placeholder : "针对这段引用，你想问什么？",
                          text: $session.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { session.send(session.draft) }
                    .draftTappable()
                Button("发送", systemImage: "paperplane.fill") { session.send(session.draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canSend)
                    .draftTappable()
            }
        }
        .onChange(of: session.focusToken) { focused = true }
        .onDisappear { session.save() }
    }
}

/// 重做记录里的历史讲评，只展示已经保存的内容。
struct SavedChatThreadView: View {
    let conversation: SavedConversation
    var pack: StudyPack?
    @Environment(\.renderScale) private var renderScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(conversation.messages.enumerated()), id: \.offset) { _, message in
                if message.role == "user" {
                    if let quote = message.quote {
                        QuoteChip(quote: SelectionQuote(text: quote.text, source: quote.source, paragraph: quote.paragraph))
                    }
                    MathText.text(message.shown, font: .preferredFont(forTextStyle: .body), scale: renderScale)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ModelBadge(usage: message.usage)
                    if message.incomplete == true { Text("未完成的回答").font(.caption).foregroundStyle(.secondary) }
                    MarkdownView(text: message.text, pack: pack)
                }
            }
            if !conversation.partialText.isEmpty {
                ModelBadge(usage: conversation.partialUsage)
                Text("未完成的回答").font(.caption).foregroundStyle(.secondary)
                MarkdownView(text: conversation.partialText, pack: pack)
            }
        }
    }
}

/// 引用的出处与引文
struct QuoteChip: View {
    let quote: SelectionQuote

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("引用自\(quote.source)").font(.caption.bold()).foregroundStyle(.tint)
                Text(ChatSession.clip(quote.text, 120)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
