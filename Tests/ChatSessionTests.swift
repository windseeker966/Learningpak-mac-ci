import Foundation
import Observation

// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor -module-cache-path /tmp/learning-swift-module-cache Learning/AI/{LLMSettings,LLMEndpoint,LLMUsage,LLMClient,StreamRunner,SelectionQuote,ChatSession}.swift Learning/Records/SavedConversation.swift Tests/ChatSessionTests.swift -o /tmp/chat-session-tests
// /tmp/chat-session-tests
nonisolated private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    func set() { lock.lock(); changed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
}

@main
private enum ChatSessionTests {
    static func main() async throws {
        let session = ChatSession()
        let longText = String(repeating: "步骤：$a^2+b^2=c^2$。", count: 3000)
        let original = SavedConversation(system: "依据参考答案讲评", context: [.init(role: "user", text: "题面和参考答案")],
            messages: [.init(role: "assistant", text: longText, shown: longText)], draft: "", pendingQuote: nil,
            partialText: "", error: nil)
        session.restore(original)
        var saved: [SavedConversation] = []
        var lastEncodingMS = 0.0
        session.onSave = { snapshot in
            let start = ContinuousClock.now
            _ = try! JSONEncoder().encode(snapshot)
            lastEncodingMS = Double(start.duration(to: .now).components.attoseconds) / 1e15
            saved.append(snapshot)
        }
        let invalidated = ChangeFlag()
        withObservationTracking {
            _ = session.messages
            _ = session.runner.isRunning
            _ = session.runner.error
        } onChange: { invalidated.set() }
        let typingStart = ContinuousClock.now
        for character in "我想知道这道题为什么必须先完成第一步，再分析第二步的条件。" {
            session.draft.append(character)
            try await Task.sleep(for: .milliseconds(8))
        }
        precondition(saved.isEmpty, "连续输入时不能每个字符都保存整段对话")
        precondition(!invalidated.value, "编辑输入框不能使消息正文的观察失效")
        try await Task.sleep(for: .milliseconds(750))
        precondition(saved.count == 1 && saved[0].draft == session.draft)
        session.pendingQuote = SelectionQuote(text: "第一步", source: "讲评", paragraph: "先完成第一步")
        session.draft = "修改后的追问"
        session.save() // 离开或退到后台须立即保存，不依赖计时器。
        precondition(saved.count == 2 && saved[1].pendingQuote?.text == "第一步")
        try await Task.sleep(for: .milliseconds(750))
        precondition(saved.count == 2, "已立即保存后不可再触发排队中的保存")
        let data = try JSONEncoder().encode(session.snapshot)
        let recovered = ChatSession()
        recovered.restore(try JSONDecoder().decode(SavedConversation.self, from: data))
        precondition(recovered.draft == "修改后的追问" && recovered.messages.first?.text == longText)
        precondition(recovered.pendingQuote?.text == "第一步")
        session.draft = "不能串到重做记录的旧草稿"
        session.reset()
        try await Task.sleep(for: .milliseconds(750))
        precondition(saved.count == 2 && session.messages.isEmpty && session.draft.isEmpty)
        let total = typingStart.duration(to: .now)
        print("Chat draft checks passed: one deferred save, isolated text observation, immediate flush, restore and reset; encoding \(lastEncodingMS) ms; total \(total)")
    }
}
