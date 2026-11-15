import SwiftUI

/// 列表按供应商缓存（LLMModels.cached），没有缓存时自动获取一次，之后手动点「重新获取」才更新；接口不支持列表时仍可手填。
struct ProviderModelsRow: View {
    let config: LLMConfig
    @Binding var models: [LLMModel]
    @Binding var defaultModel: String
    @State private var fetchedAt: Date?
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var task: Task<Void, Never>?

    private struct Connection: Equatable {
        let proto: LLMProtocol
        let url: String
        let key: String
    }
    private var connection: Connection { .init(proto: config.proto, url: config.baseURL, key: config.apiKey) }

    var body: some View {
        HStack {
            Button(loading ? "正在获取模型…" : models.isEmpty ? "获取模型列表" : "重新获取模型列表",
                   systemImage: "arrow.clockwise") { load() }
                .disabled(loading || config.apiKey.isEmpty || config.baseURL.isEmpty)
            Spacer()
            if !models.isEmpty {
                Menu("选择默认模型") {
                    ForEach(models) { model in
                        Button(model.label) { defaultModel = model.id }
                    }
                }
            }
            if loading { ProgressView() }
        }
            // 先用缓存；这家供应商还没获取过才自动获取一次。修改地址后换成对应的缓存，没有缓存时由用户点击获取。
            .task {
                guard models.isEmpty else { return }
                if !useCache() && !config.apiKey.isEmpty { load() }
            }
            .onChange(of: connection) { _, _ in
                task?.cancel()
                requestID = UUID()
                loading = false
                error = nil
                if !useCache() { models = []; fetchedAt = nil }
            }
            .onDisappear { task?.cancel(); requestID = UUID(); loading = false }
        if let error {
            Text(error).font(.footnote).foregroundStyle(.secondary)
        } else if !models.isEmpty {
            Text("接口返回 \(models.count) 个模型\(fetchedAt.map { "（\($0.formatted(.dateTime.month().day().hour().minute())) 获取）" } ?? "")，细分设置也可从中选择。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// 换成缓存的列表；没有缓存时返回 false
    private func useCache() -> Bool {
        guard let cache = LLMModels.cached(for: config) else { return false }
        models = cache.models
        fetchedAt = cache.fetchedAt
        return true
    }

    private func load() {
        task?.cancel()
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        let config = config
        task = Task {
            do {
                let result = try await LLMModels().fetch(config: config)
                guard requestID == id, !Task.isCancelled else { return }
                models = result
                fetchedAt = LLMModels.saveCache(result, for: config).fetchedAt
            } catch {
                guard requestID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct PurposeModelRow: View {
    let purpose: LLMPurpose
    let primaryDefault: String
    let primaryModels: [LLMModel]
    let backupModels: [LLMModel]
    let backupEnabled: Bool
    @AppStorage private var model: String
    @AppStorage private var provider: String
    @AppStorage private var fallbacksRaw: String

    init(purpose: LLMPurpose, primaryDefault: String, primaryModels: [LLMModel],
         backupModels: [LLMModel], backupEnabled: Bool) {
        self.purpose = purpose
        self.primaryDefault = primaryDefault
        self.primaryModels = primaryModels
        self.backupModels = backupModels
        self.backupEnabled = backupEnabled
        _model = AppStorage(wrappedValue: "", purpose.modelKey)
        _provider = AppStorage(wrappedValue: LLMProvider.primary.rawValue, purpose.providerKey)
        _fallbacksRaw = AppStorage(wrappedValue: "", purpose.fallbacksKey)
    }

    private var fallbacks: [LLMFallbackModel] {
        get { LLMFallbackModel.decode(fallbacksRaw) }
        nonmutating set { fallbacksRaw = LLMFallbackModel.encode(newValue) }
    }

    var body: some View {
        LabeledContent(purpose.label) {
            ModelChoiceField(placeholder: primaryDefault.isEmpty ? "留空使用主供应商默认模型" : "默认：\(primaryDefault)",
                             model: $model,
                             provider: Binding(get: { LLMProvider(rawValue: provider) ?? .primary },
                                               set: { provider = $0.rawValue }),
                             primaryModels: primaryModels, backupModels: backupModels, backupEnabled: backupEnabled,
                             accessibilityLabel: "选择\(purpose.label)模型") {
                Button("使用主供应商默认模型") {
                    model = ""
                    provider = LLMProvider.primary.rawValue
                    fallbacks = []
                }
            }
        }
        // 回退模型各占一行，排在所属细分模型下方
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ForEach(fallbacks) { item in
                HStack {
                    ModelChoiceField(placeholder: "回退模型名", model: fallbackBinding(item.id, \.model),
                                     provider: fallbackBinding(item.id, \.provider),
                                     primaryModels: primaryModels, backupModels: backupModels, backupEnabled: backupEnabled,
                                     accessibilityLabel: "选择\(purpose.label)回退模型") { EmptyView() }
                    Button("删除回退模型", systemImage: "minus.circle.fill") {
                        fallbacks.removeAll { $0.id == item.id }
                    }
                    .labelStyle(.iconOnly).foregroundStyle(.red).buttonStyle(.borderless)
                }
            }
            HStack {
                Spacer()
                Button("添加回退模型", systemImage: "plus.circle") {
                    fallbacks.append(LLMFallbackModel(model: "", provider: .primary))
                }
                .font(.caption).buttonStyle(.borderless)
            }
        }
    }

    private func fallbackBinding<Value>(_ id: UUID, _ path: WritableKeyPath<LLMFallbackModel, Value>) -> Binding<Value> {
        Binding(get: { (fallbacks.first { $0.id == id } ?? LLMFallbackModel(model: "", provider: .primary))[keyPath: path] },
                set: { value in
                    var list = fallbacks
                    guard let index = list.firstIndex(where: { $0.id == id }) else { return }
                    list[index][keyPath: path] = value
                    fallbacks = list
                })
    }
}

/// 模型名输入框加下拉菜单。从哪个供应商的列表选，就用哪个供应商的地址和密钥请求；
/// 手填时按模型列表判断所属供应商，两边列表都没有则保持原来的供应商。
private struct ModelChoiceField<ExtraItems: View>: View {
    let placeholder: String
    @Binding var model: String
    @Binding var provider: LLMProvider
    let primaryModels: [LLMModel]
    let backupModels: [LLMModel]
    let backupEnabled: Bool
    let accessibilityLabel: String
    @ViewBuilder let extraItems: () -> ExtraItems

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack {
                TextField(placeholder, text: Binding(get: { model }, set: { typed($0) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                Menu {
                    extraItems()
                    Section("主供应商") {
                        if primaryModels.isEmpty { Text("请先获取主供应商模型列表") }
                        ForEach(primaryModels) { item in
                            Button(item.label) { provider = .primary; model = item.id }
                        }
                    }
                    if backupEnabled {
                        Section("备用供应商") {
                            if backupModels.isEmpty { Text("请先获取备用供应商模型列表") }
                            ForEach(backupModels) { item in
                                Button(item.label) { provider = .backup; model = item.id }
                            }
                        }
                    }
                } label: { Image(systemName: "chevron.down.circle") }
                    .accessibilityLabel(accessibilityLabel)
            }
            if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if provider == .backup && !backupEnabled {
                    Text("备用供应商未启用，不会请求").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("通过\(provider.label)请求").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func typed(_ value: String) {
        model = value
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let inPrimary = primaryModels.contains { $0.id == id }
        let inBackup = backupEnabled && backupModels.contains { $0.id == id }
        if provider == .primary ? (!inPrimary && inBackup) : (!inBackup && inPrimary) {
            provider = provider == .primary ? .backup : .primary
        }
    }
}
