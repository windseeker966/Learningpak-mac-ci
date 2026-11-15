import Foundation
import Observation

/// 一段可追问的对话。context 是不展示的前置上下文（如讲解原文、讲评请求），messages 是界面上展示的对话。
@Observable
final class ChatSession {
    struct Message {
        let role: ChatTurn.Role
        /// 发给模型的完整内容（含引用的出处和所在段落）
        let text: String
        /// 界面上显示的内容
        let shown: String
        var quote: SelectionQuote?
        var incomplete = false
        var usage: LLMUsage? = nil
        /// App 自动发送的消息（如按 AI 的查阅请求取出的原文），界面上只显示一行说明
        var auto = false
    }

    var system: String
    var context: [ChatTurn]
    /// 输入框发送时用的模型用途
    var sendPurpose: LLMPurpose = .followUp
    /// 开场请求（start）用的模型用途；恢复保存的对话后，接着生成开场回答时沿用
    var startPurpose: LLMPurpose = .questionReview
    private(set) var messages: [Message] = []
    var draft = "" { didSet { scheduleDraftSave() } }
    /// 划选后待发送的引用，显示在输入框上方
    var pendingQuote: SelectionQuote? { didSet { scheduleDraftSave() } }
    /// 自增即请求输入框获取焦点
    private(set) var focusToken = 0
    let runner = StreamRunner()
    /// 由宿主绑定到本次作答记录；讲解页等未绑定的对话仍可单独使用。
    @ObservationIgnored var onSave: ((SavedConversation) -> Void)?
    /// 每次请求模型之前调用，可在这里刷新 system（如最新的学习进度）
    @ObservationIgnored var beforeStream: (() -> Void)?
    /// 一条回答完成后调用：返回要自动接着发送的内容（text 发给模型，shown 显示在界面上），nil 表示不再自动发送
    @ObservationIgnored var followUp: ((String) -> (text: String, shown: String)?)?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var restoring = false

    init(system: String = "", context: [ChatTurn] = []) {
        self.system = system
        self.context = context
    }

    var isBusy: Bool { runner.isRunning }
    var canSend: Bool { !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 不展示用户消息，直接让模型开口（如答后讲评）
    func start(system: String, hidden: [ChatTurn], purpose: LLMPurpose = .questionReview) {
        self.system = system
        context = hidden
        messages = []
        startPurpose = purpose
        stream(purpose: purpose)
        save()
    }

    func send(_ question: String, purpose: LLMPurpose? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isBusy else { return }
        archivePartialAnswer()
        let quote = pendingQuote
        messages.append(Message(role: .user, text: Self.compose(question: q, quote: quote), shown: q, quote: quote))
        draft = ""
        pendingQuote = nil
        save()
        stream(purpose: purpose ?? sendPurpose)
    }

    func handle(_ action: SelectionAction) {
        switch action {
        case .ask(let quote):
            pendingQuote = quote
            focusToken += 1
        case .explain(let quote):
            pendingQuote = quote
            send("请解释这段话。", purpose: .explanation)
        }
    }

    func reset() {
        pendingSave?.cancel()
        restoring = true
        defer { restoring = false }
        runner.cancel()
        runner.text = ""
        runner.error = nil
        runner.usage = nil
        messages = []
        lastPurpose = nil
        draft = ""
        pendingQuote = nil
    }

    /// 最近一次请求的用途，重新回答时沿用；恢复保存的对话后为 nil，按有没有提问过推断
    @ObservationIgnored private var lastPurpose: LLMPurpose?
    private var resumePurpose: LLMPurpose {
        lastPurpose ?? (messages.contains { $0.role == .user && !$0.auto } ? sendPurpose : startPurpose)
    }

    /// 能重新回答：最后一条是 AI 的回答
    var canRegenerate: Bool { !isBusy && messages.last?.role == .assistant }

    /// 去掉最后一条回答重新生成；useBackup 时改用备用供应商的默认模型
    func regenerate(useBackup: Bool) {
        guard canRegenerate else { return }
        messages.removeLast()
        stream(purpose: resumePurpose, useBackup: useBackup)
        save()
    }

    /// 上一次请求没有得到完整的回答（生成中途离开、出错）：对话（含不展示的开场请求）的最后一条是提问
    var canResume: Bool { !isBusy && (messages.last?.role ?? context.last?.role) == .user }

    /// 重新生成这次回答，丢掉未完成的文字
    func resume(useBackup: Bool) {
        guard canResume else { return }
        runner.text = ""
        stream(purpose: resumePurpose, useBackup: useBackup)
        save()
    }

    private func stream(purpose: LLMPurpose, useBackup: Bool = false) {
        lastPurpose = purpose
        beforeStream?()
        // 继续提问时保留上次未完成的文字，但不把它当作完整回答交给模型。
        archivePartialAnswer()
        let turns = context + messages.filter { !$0.incomplete }.map { ChatTurn(role: $0.role, text: $0.text) }
        let backup = useBackup ? LLMConfig.backup() : nil
        runner.run(system: system, messages: Self.normalized(turns), config: backup ?? .current(purpose),
                   backup: backup == nil ? .backup() : nil, onUpdate: { [weak self] _ in
            self?.save()
        }) { [weak self] answer in
            guard let self else { return }
            messages.append(Message(role: .assistant, text: answer, shown: answer, usage: runner.usage))
            runner.text = ""
            if let next = followUp?(answer) {
                messages.append(Message(role: .user, text: next.text, shown: next.shown, auto: true))
                stream(purpose: purpose, useBackup: useBackup)
                return
            }
            save()
        }
        save()
    }

    private func archivePartialAnswer() {
        guard !runner.text.isEmpty else { return }
        messages.append(Message(role: .assistant, text: runner.text, shown: runner.text, incomplete: true, usage: runner.usage))
        runner.text = ""
    }

    /// 打字只更新输入区；停顿后再编码整段历史，离开、发送时立即保存。
    private func scheduleDraftSave() {
        guard !restoring, onSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !context.isEmpty || !messages.isEmpty || !runner.text.isEmpty || !draft.isEmpty || pendingQuote != nil else { return }
        onSave?(snapshot)
    }

    var snapshot: SavedConversation {
        SavedConversation(system: system,
            context: context.map { .init(role: $0.role.rawValue, text: $0.text) },
            messages: messages.map { .init(role: $0.role.rawValue, text: $0.text,
                shown: $0.shown, quote: Self.savedQuote($0.quote), incomplete: $0.incomplete, usage: $0.usage,
                auto: $0.auto ? true : nil) },
            draft: draft, pendingQuote: Self.savedQuote(pendingQuote),
            partialText: runner.text, error: runner.error, partialUsage: runner.usage)
    }

    func restore(_ saved: SavedConversation) {
        pendingSave?.cancel()
        restoring = true
        defer { restoring = false }
        runner.cancel()
        lastPurpose = nil
        system = saved.system
        context = saved.context.compactMap { turn in
            ChatTurn.Role(rawValue: turn.role).map { ChatTurn(role: $0, text: turn.text) }
        }
        // 以前的对话可能带着已经停用的整节比喻框架
        let rule = "已停用整节比喻框架：后续回答不要沿用前文中的比喻场景或角色。"
        if system.contains("【本节比喻框架】") || context.contains(where: { $0.text.contains("【本节比喻框架】") }) {
            if !system.contains(rule) { system += "\n" + rule }
        }
        messages = saved.messages.compactMap { message in
            ChatTurn.Role(rawValue: message.role).map {
                Message(role: $0, text: message.text, shown: message.shown,
                        quote: Self.restoredQuote(message.quote), incomplete: message.incomplete ?? false, usage: message.usage,
                        auto: message.auto ?? false)
            }
        }
        draft = saved.draft
        pendingQuote = Self.restoredQuote(saved.pendingQuote)
        runner.text = saved.partialText
        runner.usage = saved.partialUsage
        runner.error = saved.error ?? (saved.partialText.isEmpty ? nil : "上次回答未完成，已保留生成的内容。")
    }

    private static func savedQuote(_ quote: SelectionQuote?) -> SavedConversation.Quote? {
        quote.map { .init(text: $0.text, source: $0.source, paragraph: $0.paragraph) }
    }

    private static func restoredQuote(_ quote: SavedConversation.Quote?) -> SelectionQuote? {
        quote.map { .init(text: $0.text, source: $0.source, paragraph: $0.paragraph) }
    }

    /// 发给模型的消息：写明引文出自哪里、在哪一段，再接用户的问题
    static func compose(question: String, quote: SelectionQuote?) -> String {
        guard let quote else { return question }
        var s = "我引用了\(quote.source)中的这段话：\n「\(clip(quote.text, 300))」\n"
        if quote.paragraph != quote.text && quote.paragraph.count > quote.text.count {
            s += "（它所在的段落：\(clip(quote.paragraph, 800))）\n"
        }
        return s + "\n" + question
    }

    /// 上一轮失败留下的连续用户消息合并成一条，保证 user / assistant 交替
    private static func normalized(_ turns: [ChatTurn]) -> [ChatTurn] {
        var out: [ChatTurn] = []
        for t in turns where !t.text.isEmpty {
            if let last = out.last, last.role == t.role {
                out[out.count - 1] = ChatTurn(role: t.role, text: last.text + "\n\n" + t.text, images: last.images + t.images)
            } else {
                out.append(t)
            }
        }
        return out
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}

