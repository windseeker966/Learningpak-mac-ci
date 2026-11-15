import Foundation

// swiftc -swift-version 6 -module-cache-path /tmp/learning-swift-module-cache -parse-as-library -default-isolation MainActor Learning/AI/{LLMSettings,LLMEndpoint,LLMModels,LLMUsage,LLMClient}.swift Tests/LLMSettingsTests.swift -o /tmp/llm-settings-tests
// /tmp/llm-settings-tests
nonisolated private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(Int, String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated private static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies.isEmpty ? (500, "unexpected request") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    nonisolated static func reset(_ replies: [(Int, String)]) {
        lock.lock(); defer { lock.unlock() }
        Self.replies = replies
        requests = []
    }
    nonisolated static func captured() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

@main
private enum LLMSettingsTests {
    private static func requestBody(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { preconditionFailure("请求缺少 body") }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    static func main() async throws {
        let defaults = UserDefaults(suiteName: "LLMSettingsTests-\(UUID())")!
        let primary = LLMConfig(proto: .openAI, baseURL: "https://primary.example/v1", model: "primary-default",
                                apiKey: "primary-test-key", effort: "", fallback: false)
        let backup = LLMConfig(proto: .openAI, baseURL: "https://backup.example/custom/v1/chat/completions",
                               model: "backup-default", apiKey: "backup-test-key", effort: "", fallback: false, provider: .backup)
        defaults.set(true, forKey: SettingsKey.backupEnabled)
        for purpose in LLMPurpose.configurable {
            precondition(LLMConfig.resolve(purpose, defaults: defaults, primary: primary, backup: backup).model == primary.model)
            defaults.set("special-\(purpose.rawValue)", forKey: purpose.modelKey)
            defaults.set("backup", forKey: purpose.providerKey)
            let selected = LLMConfig.resolve(purpose, defaults: defaults, primary: primary, backup: backup)
            precondition(selected.model == "special-\(purpose.rawValue)" && selected.apiKey == backup.apiKey && selected.baseURL == backup.baseURL)
            precondition(selected.provider == .backup)
            defaults.set(" \n ", forKey: purpose.modelKey)
            precondition(LLMConfig.resolve(purpose, defaults: defaults, primary: primary, backup: backup).model == primary.model)
        }
        defaults.set("grading-first", forKey: LLMPurpose.grading.modelKey)
        defaults.set("primary", forKey: LLMPurpose.grading.providerKey)
        defaults.set(LLMFallbackModel.encode([LLMFallbackModel(model: "fb-backup", provider: .backup),
                                              LLMFallbackModel(model: " ", provider: .primary),
                                              LLMFallbackModel(model: "fb-primary", provider: .primary)]),
                     forKey: LLMPurpose.grading.fallbacksKey)
        let chained = LLMConfig.resolve(.grading, defaults: defaults, primary: primary, backup: backup)
        precondition(chained.fallbackModels.map(\.model) == ["fb-backup", "fb-primary"], "空回退项应忽略")
        precondition(chained.fallbackModels[0].baseURL == backup.baseURL && chained.fallbackModels[0].apiKey == backup.apiKey)
        precondition(chained.fallbackModels[1].baseURL == primary.baseURL && chained.fallbackModels[1].provider == .primary)
        defaults.set("", forKey: LLMPurpose.grading.modelKey)
        precondition(LLMConfig.resolve(.grading, defaults: defaults, primary: primary, backup: backup).fallbackModels.isEmpty, "细分模型留空时不用回退模型")
        defaults.set("backup-special", forKey: LLMPurpose.grading.modelKey)
        defaults.set("backup", forKey: LLMPurpose.grading.providerKey)
        defaults.set(false, forKey: SettingsKey.backupEnabled)
        precondition(!LLMConfig.resolve(.grading, defaults: defaults, primary: primary, backup: backup).fallbackModels[0].isConfigured, "备用供应商关闭后其回退模型不请求")
        precondition(!LLMConfig.resolve(.grading, defaults: defaults, primary: primary, backup: backup).isConfigured)
        defaults.set("old-lecture", forKey: SettingsKey.lectureModel)
        LLMPurpose.migrate(in: defaults)
        precondition(defaults.string(forKey: LLMPurpose.recap.modelKey) == " \n ", "不能覆盖已经设置的细分模型")
        let fresh = UserDefaults(suiteName: "LLMLegacyTests-\(UUID())")!
        fresh.set("old-lecture", forKey: SettingsKey.lectureModel)
        LLMPurpose.migrate(in: fresh)
        precondition(fresh.string(forKey: LLMPurpose.recap.modelKey) == "old-lecture")
        fresh.set("", forKey: LLMPurpose.recap.modelKey)
        LLMPurpose.migrate(in: fresh)
        precondition(fresh.string(forKey: LLMPurpose.recap.modelKey) == "")
        let reading = UserDefaults(suiteName: "LLMVocabPassageTests-\(UUID())")!
        reading.set("reading-model", forKey: LLMPurpose.readingPractice.modelKey)
        reading.set("backup", forKey: LLMPurpose.readingPractice.providerKey)
        LLMPurpose.migrate(in: reading)
        precondition(reading.string(forKey: LLMPurpose.vocabPassage.modelKey) == "reading-model", "短文复习沿用阅读练习的模型")
        precondition(reading.string(forKey: LLMPurpose.vocabPassage.providerKey) == "backup")
        precondition(reading.object(forKey: LLMPurpose.vocabPassage.fallbacksKey) == nil)
        reading.set("", forKey: LLMPurpose.vocabPassage.modelKey)
        LLMPurpose.migrate(in: reading)
        precondition(reading.string(forKey: LLMPurpose.vocabPassage.modelKey) == "", "只迁移一次，之后的修改不被覆盖")

        let cases: [(String, LLMProtocol, String)] = [
            ("https://example.com", .openAI, "/v1/models"),
            ("https://example.com/v1beta/openai/", .openAI, "/v1beta/openai/models"),
            ("https://example.com/proxy/v1/chat/completions?tenant=demo", .openAI, "/proxy/v1/models"),
            ("https://example.com", .anthropic, "/v1/models"),
            ("https://example.com/anthropic/v1/messages", .anthropic, "/anthropic/v1/models"),
            ("https://api.deepseek.com/anthropic", .anthropic, "/models"),
            ("https://api.deepseek.com/anthropic/v1/messages", .anthropic, "/models"),
            ("https://api.deepseek.com/v1", .openAI, "/models"),
            ("https://api.deepseek.com.evil.example/anthropic", .anthropic, "/anthropic/v1/models")
        ]
        for (base, proto, expected) in cases {
            precondition(LLMEndpoint.modelsURL(baseURL: base, proto: proto)?.path == expected)
        }
        var anthropic = primary
        anthropic.proto = .anthropic
        anthropic.baseURL = "https://anthropic.example/prefix/v1/messages?tenant=demo"
        let request = try LLMModels.request(config: anthropic, after: "model-last")
        precondition(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "x-api-key") == primary.apiKey)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(items.contains(URLQueryItem(name: "tenant", value: "demo")) && items.contains(URLQueryItem(name: "after_id", value: "model-last")))
        let openAIRequest = try LLMModels.request(config: backup)
        precondition(openAIRequest.value(forHTTPHeaderField: "Authorization") == "Bearer backup-test-key")
        precondition(openAIRequest.value(forHTTPHeaderField: "x-api-key") == nil)

        var deepseek = anthropic
        deepseek.baseURL = "https://api.deepseek.com/anthropic"
        let deepseekRequest = try LLMModels.request(config: deepseek)
        precondition(deepseekRequest.url?.path == "/models" && deepseekRequest.url?.query == nil)
        precondition(deepseekRequest.value(forHTTPHeaderField: "Authorization") == "Bearer primary-test-key")
        precondition(deepseekRequest.value(forHTTPHeaderField: "x-api-key") == nil)
        precondition(LLMEndpoint.url(baseURL: deepseek.baseURL, proto: deepseek.proto)?.path == "/anthropic/v1/messages", "不能改变可用的聊天地址")
        let deepseekPage = try JSONDecoder().decode(LLMModelPage.self, from: Data(#"{"data":[{"id":"deepseek-flash","name":"DeepSeek Flash"}]}"#.utf8))
        precondition(deepseekPage.data.first?.displayName == "DeepSeek Flash")

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        StubProtocol.reset([(200, #"{"data":[{"id":"b","display_name":"B"}],"has_more":true,"last_id":"b"}"#),
                            (200, #"{"data":[{"id":"b"},{"id":"a"}],"has_more":false}"#)])
        let models = try await LLMModels(session: session).fetch(config: anthropic)
        precondition(models.map(\.id) == ["a", "b"] && StubProtocol.captured().count == 2)
        StubProtocol.reset([(200, #"{"data":[],"has_more":true,"last_id":"repeat"}"#),
                            (200, #"{"data":[],"has_more":true,"last_id":"repeat"}"#)])
        do { _ = try await LLMModels(session: session).fetch(config: anthropic); preconditionFailure("重复游标应停止") }
        catch LLMModelsError.pagination {}
        StubProtocol.reset([(403, "do not expose response")])
        do { _ = try await LLMModels(session: session).fetch(config: primary); preconditionFailure("HTTP 错误应提示") }
        catch LLMModelsError.http(403) {}

        let success = "data: {\"model\":\"reported-backup\",\"choices\":[{\"delta\":{\"content\":\"backup answer\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        var special = primary
        special.model = "grading-special"
        var diagnosticEvents: [(String, [String: Any])] = []
        StubProtocol.reset([(404, #"{"error":{"message":"unknown model"}}"#), (200, success)])
        let answer = try await LLMClient(config: special, backup: backup, session: session,
                                        diagnostics: { diagnosticEvents.append(($0, $1)) }).complete(system: "test", messages: [])
        precondition(diagnosticEvents.map { $0.0 } == ["llm_attempt_start", "llm_attempt_failure", "llm_fallback", "llm_attempt_start", "llm_attempt_success"])
        precondition(diagnosticEvents[1].1["http_status"] as? Int == 404 && diagnosticEvents[1].1["error_kind"] as? String == "http")
        precondition(diagnosticEvents.last?.1["finish_reason"] as? String == "stop")
        let captured = StubProtocol.captured()
        precondition(captured.count == 2 && captured[1].url?.host == "backup.example")
        let body = try JSONSerialization.jsonObject(with: requestBody(captured[1])) as! [String: Any]
        precondition(body["model"] as? String == "backup-default", "回退不可沿用细分模型")
        precondition(answer.text == "backup answer" && answer.usage.isBackup && answer.usage.model == "reported-backup")
        var backupSpecial = backup
        backupSpecial.model = "backup-special"
        StubProtocol.reset([(404, "unknown"), (200, success)])
        _ = try await LLMClient(config: backupSpecial, backup: backup, session: session).complete(system: "test", messages: [])
        precondition(StubProtocol.captured().count == 2)
        StubProtocol.reset([(404, "unknown")])
        do { _ = try await LLMClient(config: backup, backup: backup, session: session).complete(system: "test", messages: []); preconditionFailure() }
        catch { precondition(StubProtocol.captured().count == 1, "同一默认模型失败不能再重复调用") }
        StubProtocol.reset([(200, success)])
        let direct = try await LLMClient(config: backupSpecial, backup: backup, session: session).complete(system: "test", messages: [])
        precondition(direct.usage.isBackup && StubProtocol.captured().count == 1)

        // 所选模型临时性失败（5xx、429、网络）先重试一次，成功就不回退；404 这类配置错误不重试（见上面的 llm_fallback 用例）
        diagnosticEvents = []
        StubProtocol.reset([(503, "busy"), (200, success)])
        let retried = try await LLMClient(config: special, backup: backup, session: session,
                                         diagnostics: { diagnosticEvents.append(($0, $1)) }).complete(system: "test", messages: [])
        precondition(StubProtocol.captured().count == 2 && !retried.usage.isBackup)
        precondition(diagnosticEvents.map { $0.0 }.filter { $0 == "llm_retry" || $0 == "llm_fallback" } == ["llm_retry"])
        StubProtocol.reset([(429, "slow down"), (200, success)])
        _ = try await LLMClient(config: backup, backup: backup, session: session).complete(system: "test", messages: [])
        precondition(StubProtocol.captured().count == 2, "没有回退目标时也重试一次")
        precondition(LLMClient.isTransient(URLError(.timedOut)) && !LLMClient.isTransient(LLMError.refusal)
                     && !LLMClient.isTransient(LLMError.http(401, "", endpoint: "")))

        // 回退链：所选模型（重试一次）→ 回退模型（依次，跳过重复与未配置）→ 备用供应商默认模型
        var fbBackup = backup
        fbBackup.model = "fb-backup"
        var fbDisabled = backup
        fbDisabled.model = "fb-disabled"
        fbDisabled.apiKey = ""
        var chain = special
        chain.fallbackModels = [fbBackup, special, fbDisabled, backup]
        diagnosticEvents = []
        StubProtocol.reset([(500, "first down"), (500, "still down"), (404, "fb down"), (200, success)])
        let chainedAnswer = try await LLMClient(config: chain, backup: backup, session: session,
                                               diagnostics: { diagnosticEvents.append(($0, $1)) }).complete(system: "test", messages: [])
        let chainBodies = try StubProtocol.captured().map { try JSONSerialization.jsonObject(with: requestBody($0)) as! [String: Any] }
        precondition(chainBodies.map { $0["model"] as? String } == ["grading-special", "grading-special", "fb-backup", "backup-default"])
        precondition(diagnosticEvents.filter { $0.0 == "llm_fallback" }.count == 2 && chainedAnswer.usage.isBackup)
        var fbPrimary = primary
        fbPrimary.model = "fb-primary"
        chain.fallbackModels = [fbPrimary]
        StubProtocol.reset([(500, "first down"), (500, "still down"), (200, success)])
        let fbAnswer = try await LLMClient(config: chain, backup: backup, session: session).complete(system: "test", messages: [])
        precondition(StubProtocol.captured().count == 3 && !fbAnswer.usage.isBackup, "回退模型成功后不再请求备用")
        StubProtocol.reset([(500, "a"), (500, "a"), (500, "b"), (500, "c")])
        do { _ = try await LLMClient(config: chain, backup: backup, session: session).complete(system: "test", messages: []); preconditionFailure() }
        catch LLMError.providersFailed(let failures) {
            precondition(failures.map(\.0) == ["所选模型（重试 1 次后）", "回退模型 fb-primary", "备用供应商默认模型"], "回退模型不重试")
        }

        // 划词翻译与生词释义关掉思考；接口不认 thinking 参数时去掉再请求一次
        let thinkingDefaults = UserDefaults(suiteName: "LLMThinkingTests-\(UUID())")!
        precondition(LLMConfig.resolve(.vocab, defaults: thinkingDefaults, primary: primary, backup: backup).disablesThinking)
        precondition(!LLMConfig.resolve(.lecture, defaults: thinkingDefaults, primary: primary, backup: backup).disablesThinking)
        thinkingDefaults.set("vocab-special", forKey: LLMPurpose.vocab.modelKey)
        thinkingDefaults.set(LLMFallbackModel.encode([LLMFallbackModel(model: "vocab-fb", provider: .primary)]),
                             forKey: LLMPurpose.vocab.fallbacksKey)
        let vocabConfig = LLMConfig.resolve(.vocab, defaults: thinkingDefaults, primary: primary, backup: backup)
        precondition(vocabConfig.disablesThinking && vocabConfig.fallbackModels[0].disablesThinking)
        var fast = anthropic
        fast.baseURL = "https://api.deepseek.com/anthropic"
        fast.effort = "high"
        fast.disablesThinking = true
        let anthropicSuccess = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        StubProtocol.reset([(200, anthropicSuccess)])
        _ = try await LLMClient(config: fast, backup: nil, session: session).complete(system: "test", messages: [])
        let fastBody = try JSONSerialization.jsonObject(with: requestBody(StubProtocol.captured()[0])) as! [String: Any]
        precondition((fastBody["thinking"] as? [String: Any])?["type"] as? String == "disabled" && fastBody["output_config"] == nil)
        StubProtocol.reset([(400, #"{"error":{"message":"unknown field: thinking"}}"#), (200, anthropicSuccess)])
        let fastRetry = try await LLMClient(config: fast, backup: backup, session: session).complete(system: "test", messages: [])
        let retryBodies = try StubProtocol.captured().map { try JSONSerialization.jsonObject(with: requestBody($0)) as! [String: Any] }
        precondition(retryBodies.count == 2 && retryBodies[1]["thinking"] == nil && !fastRetry.usage.isBackup)
        precondition((retryBodies[1]["output_config"] as? [String: Any])?["effort"] as? String == "high")

        var google = primary
        google.baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
        google.model = "models/gemini-3.8-flash"
        precondition(LLMEndpoint.modelID(google.model, baseURL: google.baseURL, proto: .openAI) == "gemini-3.8-flash")
        precondition(LLMEndpoint.modelID(google.model, baseURL: "https://proxy.example/v1", proto: .openAI) == google.model)
        precondition(LLMEndpoint.modelID(google.model, baseURL: "https://generativelanguage.googleapis.com.evil.example/v1beta/openai", proto: .openAI) == google.model)
        StubProtocol.reset([(200, #"{"data":[{"id":"models/gemini-3.8-flash"},{"id":"gemini-3.8-flash"}]}"#)])
        let googleModels = try await LLMModels(session: session).fetch(config: google)
        precondition(googleModels.map(\.id) == ["gemini-3.8-flash"])
        StubProtocol.reset([(200, success)])
        _ = try await LLMClient(config: google, backup: nil, session: session).complete(system: "private prompt", messages: [])
        let googleBody = try JSONSerialization.jsonObject(with: requestBody(StubProtocol.captured()[0])) as! [String: Any]
        precondition(googleBody["model"] as? String == "gemini-3.8-flash", "已经保存的带前缀模型也必须兼容")

        diagnosticEvents = []
        let truncated = "data: {\"choices\":[{\"delta\":{\"content\":\"private answer\"},\"finish_reason\":\"length\"}]}\n\n"
        StubProtocol.reset([(200, truncated), (200, success)])
        _ = try await LLMClient(config: special, backup: backup, session: session,
                                diagnostics: { diagnosticEvents.append(($0, $1)) }).complete(system: "private prompt", messages: [])
        let failure = diagnosticEvents.first { $0.0 == "llm_attempt_failure" }!.1
        precondition(failure["finish_reason"] as? String == "length" && failure["error_kind"] as? String == "output_limit")
        precondition(failure["text_chars"] as? Int == "private answer".count)
        let encodedDiagnostics = try JSONSerialization.data(withJSONObject: diagnosticEvents.map { $0.1 })
        let diagnosticText = String(decoding: encodedDiagnostics, as: UTF8.self)
        precondition(!diagnosticText.contains("private answer") && !diagnosticText.contains("private prompt") && !diagnosticText.contains(primary.apiKey))

        diagnosticEvents = []
        StubProtocol.reset([(400, "primary-test-key data:image/jpeg;base64,SECRET_IMAGE")])
        do {
            _ = try await LLMClient(config: special, backup: nil, session: session,
                                    diagnostics: { diagnosticEvents.append(($0, $1)) }).complete(system: "test", messages: [])
            preconditionFailure()
        } catch {
            let message = diagnosticEvents.last!.1["error_message"] as! String
            precondition(!message.contains(primary.apiKey) && !message.contains("SECRET_IMAGE"))
        }
        StubProtocol.reset([])
        let cancelled = Task {
            try Task.checkCancellation()
            return try await LLMClient(config: special, backup: backup, session: session).complete(system: "test", messages: [])
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("取消不可调用备用") }
        catch is CancellationError { precondition(StubProtocol.captured().isEmpty) }
        session.invalidateAndCancel()
        print("LLM purpose routing, model listing, migration and fallback checks passed")
    }
}
