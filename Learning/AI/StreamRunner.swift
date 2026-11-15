import Foundation
import Observation

/// 驱动一次流式生成，并把结果交给视图展示
@Observable
final class StreamRunner {
    var text = ""
    /// 是否已有文字。只在空与非空之间切换时才变，视图判断有没有内容时读它，不随每次增量刷新整张卡片
    private(set) var hasText = false
    var isRunning = false
    var error: String?
    var usage: LLMUsage?
    private var task: Task<Void, Never>?
    private var generationID = UUID()

    /// 上一次请求，供「重试」「换备用模型重试」原样再发
    private struct Request {
        let system: String
        let messages: [ChatTurn]
        let config: LLMConfig
        let backup: LLMConfig?
        let diagnostics: LLMDiagnosticSink?
        let onUpdate: ((String) -> Void)?
        let onFinish: ((String) -> Void)?
    }
    private var last: Request?

    var canRetry: Bool { last != nil && !isRunning }

    func run(system: String, messages: [ChatTurn], config: LLMConfig = .current(),
             backup: LLMConfig? = .backup(),
             diagnostics: LLMDiagnosticSink? = nil,
             onUpdate: ((String) -> Void)? = nil,
             onFinish: ((String) -> Void)? = nil) {
        last = Request(system: system, messages: messages, config: config, backup: backup, diagnostics: diagnostics,
                       onUpdate: onUpdate, onFinish: onFinish)
        start(system: system, messages: messages, config: config, backup: backup, diagnostics: diagnostics,
              onUpdate: onUpdate, onFinish: onFinish)
    }

    /// 用上一次的请求重新生成；useBackup 时改用备用供应商的默认模型（不再回退）
    func retry(useBackup: Bool) {
        guard let r = last else { return }
        let config = useBackup ? (LLMConfig.backup() ?? r.config) : r.config
        start(system: r.system, messages: r.messages, config: config, backup: useBackup ? nil : r.backup,
              diagnostics: r.diagnostics, onUpdate: r.onUpdate, onFinish: r.onFinish)
    }

    private func start(system: String, messages: [ChatTurn], config: LLMConfig, backup: LLMConfig?,
                       diagnostics: LLMDiagnosticSink?, onUpdate: ((String) -> Void)?,
                       onFinish: ((String) -> Void)?) {
        task?.cancel()
        let id = UUID()
        generationID = id
        setText("")
        error = nil
        usage = LLMUsage(model: config.model, provider: URL(string: config.baseURL)?.host ?? "供应商", isBackup: config.provider == .backup)
        isRunning = true
        task = Task {
            var lastUpdate = Date.distantPast
            // 增量先攒在这里，隔一小段时间才写进 text：每段增量都刷新会让整页逐字重排，流式时滚动卡顿
            var buffer = ""
            var lastFlush = Date.distantPast
            @MainActor func flush() {
                if text != buffer { setText(buffer) }
                lastFlush = .now
            }
            do {
                for try await event in LLMClient(config: config, backup: backup, diagnostics: diagnostics).stream(system: system, messages: messages) {
                    guard generationID == id, !Task.isCancelled else { return }
                    switch event {
                    case .started(let source):
                        buffer = ""
                        flush()
                        usage = source
                        onUpdate?(text)
                    case .model(let model):
                        if usage?.model != model || usage?.reportedByServer == false {
                            usage?.report(model: model, afterText: !buffer.isEmpty)
                            flush()
                            onUpdate?(text)
                        }
                    case .text(let piece):
                        buffer += piece
                        if text.isEmpty || Date.now.timeIntervalSince(lastFlush) >= 0.12 { flush() }
                    case .stopped(let reason):
                        usage?.finishReason = reason
                        flush()
                        onUpdate?(text)
                    }
                    if Date.now.timeIntervalSince(lastUpdate) >= 1 {
                        lastUpdate = .now
                        flush()
                        onUpdate?(text)
                    }
                }
                guard generationID == id, !Task.isCancelled else { return }
                flush()
                isRunning = false
                onFinish?(text)
            } catch is CancellationError {
                guard generationID == id else { return }
                flush()
                isRunning = false
                onUpdate?(text)
            } catch {
                guard generationID == id else { return }
                flush()
                self.error = error.localizedDescription
                isRunning = false
                onUpdate?(text)
            }
        }
    }

    private func setText(_ s: String) {
        text = s
        if hasText == s.isEmpty { hasText = !s.isEmpty }
    }

    func cancel() {
        task?.cancel()
        generationID = UUID()
        isRunning = false
    }
}
