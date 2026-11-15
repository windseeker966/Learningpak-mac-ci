import Foundation

enum LLMEndpoint {
    /// Google 的目录可能带资源前缀；兼容接口的示例使用不带 models/ 的模型名。
    /// 只处理 Google 官方兼容接口，避免改写代理供应商自己的模型 ID。
    static func modelID(_ model: String, baseURL: String, proto: LLMProtocol) -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard proto == .openAI,
              let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.host?.lowercased() == "generativelanguage.googleapis.com",
              parts.path.split(separator: "/").contains("openai"),
              model.hasPrefix("models/") else { return model }
        return String(model.dropFirst("models/".count))
    }

    /// 裸服务器地址按标准 /v1 路径处理；自定义前缀和完整接口地址保持原样。
    static func url(baseURL: String, proto: LLMProtocol) -> URL? {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https" || parts.scheme == "http",
              let host = parts.host, !host.isEmpty else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        switch proto {
        case .openAI:
            if !path.hasSuffix("/chat/completions") {
                path = (path.isEmpty ? "/v1" : path) + "/chat/completions"
            }
        case .anthropic:
            if !path.hasSuffix("/messages") {
                path += path.hasSuffix("/v1") ? "/messages" : "/v1/messages"
            }
        }
        parts.path = path
        parts.fragment = nil
        return parts.url
    }

    static func modelsURL(baseURL: String, proto: LLMProtocol) -> URL? {
        guard let endpoint = url(baseURL: baseURL, proto: proto),
              var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        if parts.host?.lowercased() == "api.deepseek.com" {
            // DeepSeek 的模型目录独立于 Anthropic Messages 前缀。
            parts.path = "/models"
        } else {
            let suffix = proto == .openAI ? "/chat/completions" : "/messages"
            parts.path = String(parts.path.dropLast(suffix.count)) + "/models"
        }
        return parts.url
    }

    static func modelsProtocol(baseURL: String, proto: LLMProtocol) -> LLMProtocol {
        URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() == "api.deepseek.com"
            ? .openAI : proto
    }

    /// 显示请求地址时不带用户名、密码、查询参数或片段。
    static func display(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? url.path
    }
}
