import Foundation

/// 可选的诊断输出，只记录请求元信息和错误，不记录提示词、回答或图片。
typealias LLMDiagnosticSink = (String, [String: Any]) -> Void

struct ChatTurn {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
    /// 随消息发送的图片（JPEG 数据），放在文字之前；需要模型支持图片输入
    var images: [Data] = []
}

enum LLMError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case http(Int, String, endpoint: String)
    case api(String)
    case refusal
    case emptyResponse
    case incompleteResponse
    case outputLimitReached
    /// 依次尝试的模型都失败；每项是「哪个模型」和错误信息
    case providersFailed([(String, String)])

    var errorDescription: String? {
        switch self {
        case .notConfigured: "尚未配置模型，请到「设置」中填写 Base URL、模型名和 API Key。"
        case .invalidURL(let s): "Base URL 无效：\(s)"
        case .http(let code, let body, let endpoint): "请求失败（HTTP \(code)）：\(body)\n请求地址：\(endpoint)"
        case .api(let msg): "接口返回错误：\(msg)"
        case .refusal: "模型拒绝回答了这次请求。"
        case .emptyResponse: "供应商没有返回回答内容。"
        case .incompleteResponse: "回答流在完成前中断。"
        case .outputLimitReached: "供应商因输出长度或上下文上限停止生成，回答未完成。请重新生成或更换模型。"
        case .providersFailed(let failures):
            failures.enumerated().map { i, f in "\(f.0)\(i == 0 ? "" : "也")失败：\(f.1)" }.joined(separator: "\n")
        }
    }
}

/// 流式调用大模型，支持 Anthropic Messages API 与 OpenAI 兼容的 Chat Completions。
struct LLMClient {
    let config: LLMConfig
    let backupConfig: LLMConfig?
    let session: URLSession
    let diagnostics: LLMDiagnosticSink?

    init(config: LLMConfig = .current(), backup: LLMConfig? = .backup(), session: URLSession = .shared,
         diagnostics: LLMDiagnosticSink? = nil) {
        self.config = config
        self.backupConfig = backup
        self.session = session
        self.diagnostics = diagnostics
    }

    /// 输出上限的默认值。Anthropic 协议必填 max_tokens，思考型模型的思考也计在内，给足余量只作兜底
    static let defaultMaxTokens = 32000

    /// 逐段返回生成的文字
    func stream(system: String, messages: [ChatTurn], maxTokens: Int = defaultMaxTokens) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamCandidates(system: system, messages: messages, maxTokens: maxTokens, out: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 依次尝试：所选模型（临时性错误先等一会儿重试一次）→ 细分设置的回退模型 → 备用供应商默认模型。
    /// 回退的模型各只发一次；取消不触发重试和回退。
    private func streamCandidates(system: String, messages: [ChatTurn], maxTokens: Int,
                                  out: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async throws {
        var candidates: [(label: String, config: LLMConfig)] = [("所选模型", config)]
        for fallback in config.fallbackModels where fallback.isConfigured && !candidates.contains(where: { $0.config.sameTarget(fallback) }) {
            candidates.append(("回退模型 \(fallback.model)", fallback))
        }
        if let backup = backupConfig, backup.isConfigured, !candidates.contains(where: { $0.config.sameTarget(backup) }) {
            candidates.append(("备用供应商默认模型", backup))
        }
        var failures: [(String, String)] = []
        for (index, candidate) in candidates.enumerated() {
            var client = LLMClient(config: candidate.config, backup: nil, session: session, diagnostics: diagnostics)
            if index > 0 {
                let previous = LLMClient(config: candidates[index - 1].config, backup: nil, session: session)
                diagnostics?("llm_fallback", ["from_model": previous.requestModel, "from_provider": previous.host,
                                              "to_model": client.requestModel, "to_provider": client.host])
            }
            var tries = 0
            while true {
                tries += 1
                do {
                    try await client.attempt(system: system, messages: messages, maxTokens: maxTokens,
                                             isBackup: candidate.config.provider == .backup, out: out)
                    return
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    // 不认识 thinking 参数的接口（返回 400）去掉它再请求一次，不计入重试次数
                    if client.config.disablesThinking, case LLMError.http(400, let body, _) = error, body.contains("thinking") {
                        diagnostics?("llm_retry_with_thinking", ["model": client.requestModel, "provider": client.host])
                        var config = client.config
                        config.disablesThinking = false
                        client = LLMClient(config: config, backup: nil, session: session, diagnostics: diagnostics)
                        tries = 0
                        continue
                    }
                    if index == 0, tries == 1, Self.isTransient(error) {
                        diagnostics?("llm_retry", ["model": client.requestModel, "provider": client.host])
                        try await Task.sleep(for: Self.retryDelay)
                        continue
                    }
                    if candidates.count == 1 { throw error }
                    failures.append((candidate.label + (tries > 1 ? "（重试 1 次后）" : ""), error.localizedDescription))
                    break
                }
            }
        }
        throw LLMError.providersFailed(failures)
    }

    /// 所选模型失败后，等这么久再重试
    static let retryDelay = Duration.seconds(2)

    /// 重试可能成功的错误：网络、限流、服务端错误、回答流中断。配置错误、拒绝回答、超出长度重试也没用
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case LLMError.http(let code, _, _): [408, 409, 425, 429].contains(code) || code >= 500
        case LLMError.api, LLMError.emptyResponse, LLMError.incompleteResponse: true
        case is URLError: true
        default: false
        }
    }

    /// 一次性取完整结果（内部仍走流式）
    func complete(system: String, messages: [ChatTurn], maxTokens: Int = defaultMaxTokens) async throws -> LLMCompletion {
        var text = ""
        var usage = usage(isBackup: config.provider == .backup)
        for try await event in stream(system: system, messages: messages, maxTokens: maxTokens) {
            switch event {
            case .started(let source): text = ""; usage = source
            case .model(let model): usage.report(model: model, afterText: !text.isEmpty)
            case .text(let piece): text += piece
            case .stopped(let reason): usage.finishReason = reason
            }
        }
        try Task.checkCancellation()
        return LLMCompletion(text: text, usage: usage)
    }

    private func usage(isBackup: Bool) -> LLMUsage {
        LLMUsage(model: requestModel, provider: host, isBackup: isBackup)
    }

    private var host: String { URL(string: config.baseURL)?.host ?? "供应商" }

    private var requestModel: String {
        LLMEndpoint.modelID(config.model, baseURL: config.baseURL, proto: config.proto)
    }

    private func attempt(system: String, messages: [ChatTurn], maxTokens: Int, isBackup: Bool,
                         out: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async throws {
        try Task.checkCancellation()
        out.yield(.started(usage(isBackup: isBackup)))
        let started = ProcessInfo.processInfo.systemUptime
        var fields: [String: Any] = ["model": requestModel, "configured_model": config.model,
                                     "provider": usage(isBackup: isBackup).provider,
                                     "protocol": config.proto.rawValue, "is_backup": isBackup,
                                     "image_count": messages.reduce(0) { $0 + $1.images.count },
                                     "image_bytes": messages.reduce(0) { $0 + $1.images.reduce(0) { $0 + $1.count } }]
        diagnostics?("llm_attempt_start", fields)
        var textChars = 0
        let emit: (LLMStreamEvent) -> Void = { event in
            switch event {
            case .model(let model): fields["reported_model"] = model
            case .text(let text):
                if textChars == 0 && !text.isEmpty { fields["first_text_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                textChars += text.count
            case .stopped(let reason): fields["finish_reason"] = reason
            case .started: break
            }
            out.yield(event)
        }
        do {
            guard config.isConfigured else { throw LLMError.notConfigured }
            let request = try makeRequest(system: system, messages: messages, maxTokens: maxTokens)
            fields["endpoint"] = LLMEndpoint.display(request.url!)
            fields["request_bytes"] = request.httpBody?.count ?? 0
            let (bytes, response) = try await session.bytes(for: request)
            fields["response_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            if let http = response as? HTTPURLResponse {
                fields["http_status"] = http.statusCode
                fields["content_type"] = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                if !(200..<300).contains(http.statusCode) {
                    var body = ""
                    for try await line in bytes.lines {
                        body += line
                        if body.count > 2000 { break }
                    }
                    throw LLMError.http(http.statusCode, Self.errorMessage(fromBody: body), endpoint: LLMEndpoint.display(request.url!))
                }
            }
            switch config.proto {
            case .anthropic: try await parseAnthropic(bytes.lines, emit)
            case .openAI: try await parseOpenAI(bytes.lines, emit)
            }
            fields["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            fields["text_chars"] = textChars
            diagnostics?("llm_attempt_success", fields)
        } catch {
            fields["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            fields["text_chars"] = textChars
            fields.merge(diagnosticError(error)) { _, new in new }
            diagnostics?("llm_attempt_failure", fields)
            throw error
        }
    }

    private func diagnosticError(_ error: Error) -> [String: Any] {
        var fields: [String: Any] = [:]
        var message: String?
        switch error {
        case LLMError.http(let code, let body, _): fields["error_kind"] = "http"; fields["http_status"] = code; message = body
        case LLMError.api(let body): fields["error_kind"] = "api"; message = body
        case LLMError.notConfigured: fields["error_kind"] = "not_configured"
        case LLMError.invalidURL: fields["error_kind"] = "invalid_url"
        case LLMError.refusal: fields["error_kind"] = "refusal"
        case LLMError.emptyResponse: fields["error_kind"] = "empty_response"
        case LLMError.incompleteResponse: fields["error_kind"] = "incomplete_response"
        case LLMError.outputLimitReached: fields["error_kind"] = "output_limit"
        case is CancellationError: fields["error_kind"] = "cancelled"
        case let error as URLError: fields["error_kind"] = "network"; fields["error_code"] = error.code.rawValue
        default:
            let error = error as NSError
            fields["error_kind"] = "other"; fields["error_domain"] = error.domain; fields["error_code"] = error.code
        }
        if var message {
            if !config.apiKey.isEmpty { message = message.replacingOccurrences(of: config.apiKey, with: "[redacted]") }
            message = message.replacingOccurrences(of: "data:[^\\s\\\"']+", with: "[image omitted]", options: .regularExpression)
            fields["error_message"] = String(message.prefix(500))
        }
        return fields
    }

    // MARK: - 请求

    private func makeRequest(system: String, messages: [ChatTurn], maxTokens: Int) throws -> URLRequest {
        guard let url = LLMEndpoint.url(baseURL: config.baseURL, proto: config.proto) else {
            throw LLMError.invalidURL(config.baseURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": requestModel,
            "stream": true,
        ]

        switch config.proto {
        case .anthropic:
            body["max_tokens"] = maxTokens
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["system"] = system
            body["messages"] = messages.map { turn -> [String: Any] in
                guard !turn.images.isEmpty else { return ["role": turn.role.rawValue, "content": turn.text] }
                let images: [[String: Any]] = turn.images.map {
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                 "data": $0.base64EncodedString()]]
                }
                return ["role": turn.role.rawValue, "content": images + [["type": "text", "text": turn.text]]]
            }
            if config.disablesThinking {
                body["thinking"] = ["type": "disabled"]
            } else if !config.effort.isEmpty {
                body["output_config"] = ["effort": config.effort]
            }
            if config.fallback && supportsServerFallback(config.model) {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openAI:
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body["messages"] = [["role": "system", "content": system]]
                + messages.map { turn -> [String: Any] in
                    guard !turn.images.isEmpty else { return ["role": turn.role.rawValue, "content": turn.text] }
                    let images: [[String: Any]] = turn.images.map {
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]]
                    }
                    return ["role": turn.role.rawValue, "content": images + [["type": "text", "text": turn.text]]]
                }
        }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 服务端拒答回退目前用于 Claude Opus 5 / Fable 系列
    private func supportsServerFallback(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable")
    }

    // MARK: - 解析 SSE

    private func parseAnthropic(_ lines: AsyncLineSequence<URLSession.AsyncBytes>,
                                _ emit: (LLMStreamEvent) -> Void) async throws {
        var emittedText = false
        var completed = false
        for try await line in lines {
            try Task.checkCancellation()
            guard let json = Self.dataJSON(line) else { continue }
            switch json["type"] as? String {
            case "message_start":
                if let message = json["message"] as? [String: Any], let model = message["model"] as? String {
                    emit(.model(model))
                }
            case "content_block_start":
                if let block = json["content_block"] as? [String: Any], block["type"] as? String == "fallback" {
                    if let to = block["to"] as? [String: Any], let model = to["model"] as? String {
                        emit(.model(model))
                    }
                    if emittedText { emit(.text("\n\n> （已由供应商的备用模型接着回答）\n\n")) }
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    emittedText = emittedText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    emit(.text(text))
                }
            case "message_delta":
                if let usage = json["usage"] as? [String: Any], let iterations = usage["iterations"] as? [[String: Any]],
                   let model = iterations.last?["model"] as? String { emit(.model(model)) }
                if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    emit(.stopped(reason))
                    switch reason {
                    case "end_turn", "stop_sequence": break
                    case "max_tokens", "model_context_window_exceeded": throw LLMError.outputLimitReached
                    case "refusal": throw LLMError.refusal
                    default: throw LLMError.api("回答未完成（stop_reason: \(reason)）。")
                    }
                }
            case "message_stop": completed = true
            case "error":
                let err = json["error"] as? [String: Any]
                throw LLMError.api(err?["message"] as? String ?? "未知错误")
            default: break
            }
        }
        guard completed else { throw LLMError.incompleteResponse }
        guard emittedText else { throw LLMError.emptyResponse }
    }

    private func parseOpenAI(_ lines: AsyncLineSequence<URLSession.AsyncBytes>,
                             _ emit: (LLMStreamEvent) -> Void) async throws {
        var emittedText = false
        var completed = false
        for try await line in lines {
            try Task.checkCancellation()
            if line.trimmingCharacters(in: .whitespaces) == "data: [DONE]" { completed = true; break }
            guard let json = Self.dataJSON(line) else { continue }
            if let err = json["error"] as? [String: Any] {
                throw LLMError.api(err["message"] as? String ?? "未知错误")
            }
            if let model = json["model"] as? String { emit(.model(model)) }
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
            if let delta = choice["delta"] as? [String: Any] {
                if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw LLMError.refusal }
                if let text = delta["content"] as? String {
                    emittedText = emittedText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    emit(.text(text))
                }
            }
            // 最后一块也可能带正文；先保留它，再检查结束原因。
            // [DONE] 只表示流结束，不能把 length 当作一篇完整回答。
            if let reason = choice["finish_reason"] as? String {
                emit(.stopped(reason))
                switch reason {
                case "stop": completed = true
                case "length": throw LLMError.outputLimitReached
                case "content_filter": throw LLMError.refusal
                default: throw LLMError.api("回答未完成（finish_reason: \(reason)）。")
                }
            }
        }
        guard completed else { throw LLMError.incompleteResponse }
        guard emittedText else { throw LLMError.emptyResponse }
    }

    private static func dataJSON(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func errorMessage(fromBody body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = json["message"] as? String { return msg }
        }
        return body.isEmpty ? "（无响应内容）" : String(body.prefix(500))
    }
}
