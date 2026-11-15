import Foundation

struct LLMModel: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String?
    enum CodingKeys: String, CodingKey { case id, name; case displayName = "display_name" }
    init(id: String, displayName: String? = nil) { self.id = id; self.displayName = displayName }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            ?? values.decodeIfPresent(String.self, forKey: .name)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(displayName, forKey: .displayName)
    }
    var label: String { displayName.map { $0 == id ? id : "\($0)（\(id)）" } ?? id }
}

struct LLMModelPage: Decodable {
    let data: [LLMModel]
    let hasMore: Bool?
    let lastID: String?
    enum CodingKeys: String, CodingKey { case data; case hasMore = "has_more"; case lastID = "last_id" }
}

enum LLMModelsError: LocalizedError {
    case missingCredentials, invalidResponse, http(Int), pagination, empty
    var errorDescription: String? {
        switch self {
        case .missingCredentials: "请先填写供应商地址和 API Key。"
        case .invalidResponse: "接口没有返回有效的模型列表，可手动填写模型名。"
        case .http(let code): "获取模型列表失败（HTTP \(code)）。请检查地址、密钥及供应商是否支持模型列表接口；也可手动填写模型名。"
        case .pagination: "模型列表分页未能完成，请重试或手动填写模型名。"
        case .empty: "供应商返回的模型列表为空，可手动填写模型名。"
        }
    }
}

/// 直接向对应供应商请求列表，不保存密钥，也不把其他供应商的模型混在一起。
struct LLMModels {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func request(config: LLMConfig, after: String? = nil) throws -> URLRequest {
        guard !config.apiKey.isEmpty,
              let url = LLMEndpoint.modelsURL(baseURL: config.baseURL, proto: config.proto),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LLMModelsError.missingCredentials
        }
        let proto = LLMEndpoint.modelsProtocol(baseURL: config.baseURL, proto: config.proto)
        if proto == .anthropic {
            var items = (parts.queryItems ?? []).filter { $0.name != "limit" && $0.name != "after_id" }
            items.append(URLQueryItem(name: "limit", value: "1000"))
            if let after { items.append(URLQueryItem(name: "after_id", value: after)) }
            parts.queryItems = items
        }
        guard let requestURL = parts.url else { throw LLMModelsError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch proto {
        case .openAI: request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    func fetch(config: LLMConfig) async throws -> [LLMModel] {
        var models: [String: LLMModel] = [:]
        var after: String?
        var cursors: Set<String> = []
        for _ in 0..<20 {
            try Task.checkCancellation()
            let request = try Self.request(config: config, after: after)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw LLMModelsError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw LLMModelsError.http(response.statusCode) }
            guard let page = try? JSONDecoder().decode(LLMModelPage.self, from: data) else {
                throw LLMModelsError.invalidResponse
            }
            for model in page.data where !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let id = LLMEndpoint.modelID(model.id, baseURL: config.baseURL, proto: config.proto)
                models[id] = LLMModel(id: id, displayName: model.displayName)
            }
            if LLMEndpoint.modelsProtocol(baseURL: config.baseURL, proto: config.proto) != .anthropic || page.hasMore != true {
                guard !models.isEmpty else { throw LLMModelsError.empty }
                return models.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            }
            guard let cursor = page.lastID, !cursor.isEmpty, cursors.insert(cursor).inserted else {
                throw LLMModelsError.pagination
            }
            after = cursor
        }
        throw LLMModelsError.pagination
    }
}

/// 获取到的模型列表按供应商（协议 + 地址）存在 UserDefaults，设置页直接显示，手动点「重新获取」才再拉取
extension LLMModels {
    struct Cache: Codable {
        let models: [LLMModel]
        let fetchedAt: Date
    }

    private static func cacheKey(_ config: LLMConfig) -> String {
        "llm.models.\(config.proto.rawValue)|\(config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func cached(for config: LLMConfig) -> Cache? {
        UserDefaults.standard.data(forKey: cacheKey(config)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
    }

    @discardableResult
    static func saveCache(_ models: [LLMModel], for config: LLMConfig) -> Cache {
        let cache = Cache(models: models, fetchedAt: .now)
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: cacheKey(config)) }
        return cache
    }
}
