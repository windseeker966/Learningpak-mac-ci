import Foundation
import Security

enum LLMProtocol: String, CaseIterable, Identifiable {
    case anthropic
    case openAI = "openai"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Anthropic Messages API"
        case .openAI: "OpenAI 兼容（Chat Completions）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.deepseek.com/anthropic"
        case .openAI: "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "deepseek-flash"
        case .openAI: ""
        }
    }
}

/// 设置项的 UserDefaults 键（@AppStorage 与 LLMConfig.current 共用）
enum SettingsKey {
    static let proto = "llm.protocol"
    static let baseURL = "llm.baseURL"
    static let model = "llm.model"
    static let effort = "llm.effort"
    static let fallback = "llm.fallback"
    /// 保留旧版讲解设置键以兼容已有配置
    static let lectureModel = "llm.lectureModel"
    static let lectureEffort = "llm.lectureEffort"
    static let backupEnabled = "llm.backup.enabled"
    static let backupProtocol = "llm.backup.protocol"
    static let backupBaseURL = "llm.backup.baseURL"
    static let backupModel = "llm.backup.model"
    static let backupEffort = "llm.backup.effort"
}

/// 细分模型同时记录供应商，避免拿另一家的密钥调用模型。
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case primary, backup
    var id: String { rawValue }
    var label: String { self == .primary ? "主供应商" : "备用供应商" }
}

enum LLMPurpose: String, CaseIterable, Identifiable {
    case chat, lecture, recap, followUp, explanation, questionReview, subjectiveReview, grading, choiceVariant, subjectiveVariant, vocab, readingPractice, vocabPassage, bookChat
    var id: String { rawValue }
    static var configurable: [LLMPurpose] { allCases.filter { $0 != .chat } }
    var label: String {
        switch self {
        case .chat: "供应商默认"
        case .lecture: "知识点讲解"
        case .recap: "巩固回顾"
        case .followUp: "AI 追问"
        case .explanation: "划选解释"
        case .questionReview: "选择题讲评"
        case .subjectiveReview: "综合题讲评"
        case .grading: "手写作答批改"
        case .choiceVariant: "选择题改编"
        case .subjectiveVariant: "主观题改编"
        case .vocab: "划词翻译与生词释义"
        case .readingPractice: "回译、概括与表达复习"
        case .vocabPassage: "生词 AI 短文复习"
        case .bookChat: "全书 AI 提问"
        }
    }
    var modelKey: String { self == .lecture ? SettingsKey.lectureModel : "llm.purpose.\(rawValue).model" }
    var providerKey: String { "llm.purpose.\(rawValue).provider" }
    var fallbacksKey: String { "llm.purpose.\(rawValue).fallbacks" }

    /// 旧版讲解模型曾同时用于回顾和改编，升级时保留已有选择。
    static func migrate(in defaults: UserDefaults = .standard) {
        migrateVocabPassage(in: defaults)
        let key = "llm.purpose.migrated"
        guard !defaults.bool(forKey: key) else { return }
        if let model = defaults.string(forKey: SettingsKey.lectureModel), !model.isEmpty {
            for purpose in [Self.recap, .choiceVariant, .subjectiveVariant]
                where defaults.object(forKey: purpose.modelKey) == nil {
                defaults.set(model, forKey: purpose.modelKey)
            }
        }
        defaults.set(true, forKey: key)
    }

    /// 生词 AI 短文复习原先用「回译、概括与表达复习」的模型，单独设置时沿用那一项已有的选择
    private static func migrateVocabPassage(in defaults: UserDefaults) {
        let key = "llm.purpose.vocabPassage.migrated"
        guard !defaults.bool(forKey: key) else { return }
        for path in [\LLMPurpose.modelKey, \.providerKey, \.fallbacksKey]
            where defaults.object(forKey: vocabPassage[keyPath: path]) == nil {
            if let value = defaults.object(forKey: readingPractice[keyPath: path]) {
                defaults.set(value, forKey: vocabPassage[keyPath: path])
            }
        }
        defaults.set(true, forKey: key)
    }
}

/// 细分模型失败后依次改用的模型；与细分模型一样记录所属供应商。以 JSON 字符串存进 UserDefaults。
struct LLMFallbackModel: Codable, Equatable, Identifiable {
    var id = UUID()
    var model: String
    var provider: LLMProvider

    static func decode(_ raw: String) -> [LLMFallbackModel] {
        (try? JSONDecoder().decode([LLMFallbackModel].self, from: Data(raw.utf8))) ?? []
    }

    static func encode(_ list: [LLMFallbackModel]) -> String {
        (try? JSONEncoder().encode(list)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

struct LLMConfig: Equatable {
    var proto: LLMProtocol
    var baseURL: String
    var model: String
    var apiKey: String
    var effort: String
    var fallback: Bool
    var provider: LLMProvider = .primary
    /// 关掉思考直接回答（Anthropic 协议发 thinking: disabled，不发 effort）。查词翻译要快，deepseek-flash 默认先思考，慢一倍
    var disablesThinking = false
    /// 本配置失败后、回退到备用供应商默认模型之前，依次尝试的模型
    var fallbackModels: [LLMConfig] = []

    /// 是否会发出同一个请求（同一地址、密钥和模型），用于回退时跳过重复尝试
    func sameTarget(_ other: LLMConfig) -> Bool {
        proto == other.proto && baseURL == other.baseURL && model == other.model && apiKey == other.apiKey
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.isEmpty
    }

    /// 供应商字段始终是默认模型；细分设置不会改写这里。
    static func providerDefault(_ provider: LLMProvider) -> LLMConfig {
        let d = UserDefaults.standard
        let primary = provider == .primary
        let proto = LLMProtocol(rawValue: d.string(forKey: primary ? SettingsKey.proto : SettingsKey.backupProtocol) ?? "")
            ?? (primary ? .anthropic : .openAI)
        return LLMConfig(proto: proto,
            baseURL: d.string(forKey: primary ? SettingsKey.baseURL : SettingsKey.backupBaseURL) ?? proto.defaultBaseURL,
            model: d.string(forKey: primary ? SettingsKey.model : SettingsKey.backupModel) ?? (primary ? proto.defaultModel : ""),
            apiKey: Keychain.read(account: primary ? "apiKey" : "backupAPIKey") ?? "",
            effort: d.string(forKey: primary ? SettingsKey.effort : SettingsKey.backupEffort) ?? (primary ? "high" : ""),
            fallback: primary && (d.object(forKey: SettingsKey.fallback) as? Bool ?? true), provider: provider)
    }

    static func current(_ purpose: LLMPurpose = .chat) -> LLMConfig {
        LLMPurpose.migrate()
        return resolve(purpose, defaults: .standard, primary: providerDefault(.primary),
                       backup: providerDefault(.backup))
    }

    /// 独立解析，既可测试空值继承，也可测试供应商、模型和密钥是否成套使用。
    static func resolve(_ purpose: LLMPurpose, defaults: UserDefaults,
                        primary: LLMConfig, backup: LLMConfig) -> LLMConfig {
        guard purpose != .chat else { return primary }
        let model = (defaults.string(forKey: purpose.modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return target(purpose, model: "", provider: .primary, defaults: defaults, primary: primary, backup: backup) }
        let provider = LLMProvider(rawValue: defaults.string(forKey: purpose.providerKey) ?? "") ?? .primary
        var config = target(purpose, model: model, provider: provider, defaults: defaults, primary: primary, backup: backup)
        config.fallbackModels = LLMFallbackModel.decode(defaults.string(forKey: purpose.fallbacksKey) ?? "").compactMap {
            let model = $0.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : target(purpose, model: model, provider: $0.provider, defaults: defaults, primary: primary, backup: backup)
        }
        return config
    }

    /// 用所属供应商的地址和密钥请求指定模型；model 为空时用该供应商默认模型。
    private static func target(_ purpose: LLMPurpose, model: String, provider: LLMProvider, defaults: UserDefaults,
                               primary: LLMConfig, backup: LLMConfig) -> LLMConfig {
        var config = provider == .primary ? primary : backup
        if !model.isEmpty { config.model = model }
        if provider == .backup, !defaults.bool(forKey: SettingsKey.backupEnabled) { config.apiKey = "" }
        if purpose == .lecture, provider == .primary {
            let effort = defaults.string(forKey: SettingsKey.lectureEffort) ?? "high"
            if !effort.isEmpty { config.effort = effort }
        }
        if purpose == .vocab { config.disablesThinking = true }
        return config
    }

    /// 回退只取备用供应商默认模型，不继承任何细分模型。
    static func backup() -> LLMConfig? {
        guard UserDefaults.standard.bool(forKey: SettingsKey.backupEnabled) else { return nil }
        let config = providerDefault(.backup)
        return config.isConfigured ? config : nil
    }

    static func hasAvailableProvider(_ purpose: LLMPurpose = .chat) -> Bool {
        let config = current(purpose)
        return config.isConfigured || config.fallbackModels.contains(where: \.isConfigured) || backup() != nil
    }
}

/// API Key 存在钥匙串里，不进 UserDefaults
enum Keychain {
    private static let service = "com.wind.studypack.llm"
    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 钥匙串读取较慢，而界面每次刷新都会用到（判断是否已配置模型），所以在内存里缓存一份
    private nonisolated(unsafe) static var cached: [String: String?] = [:]

    static func read(account: String = "apiKey") -> String? {
        if let cached = cached[account] { return cached }
        let value = readFromKeychain(account: account)
        cached[account] = .some(value)
        return value
    }

    private static func readFromKeychain(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String = "apiKey") {
        cached[account] = .some(value.isEmpty ? nil : value)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard !value.isEmpty else { return }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}
