import AuthenticationServices
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(PackStore.self) private var store
    @Environment(StateCheckSession.self) private var stateCheck
    @Environment(DriveBackupSession.self) private var drive
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var pairingSecret = ""
    @State private var confirmNewSecret = false
    @AppStorage(SettingsKey.proto) private var proto = LLMProtocol.anthropic.rawValue
    @AppStorage(SettingsKey.baseURL) private var baseURL = LLMProtocol.anthropic.defaultBaseURL
    @AppStorage(SettingsKey.model) private var model = LLMProtocol.anthropic.defaultModel
    @AppStorage(SettingsKey.effort) private var effort = "high"
    @AppStorage(SettingsKey.fallback) private var fallback = true
    @AppStorage(SettingsKey.lectureEffort) private var lectureEffort = "high"
    @State private var apiKey = Keychain.read() ?? ""
    @State private var primaryModels: [LLMModel] = []
    @State private var backupModels: [LLMModel] = []
    @State private var testRunner = StreamRunner()
    @AppStorage(SettingsKey.backupEnabled) private var backupEnabled = false
    @AppStorage(SubjectiveWindow.companionKey) private var openGoodNotes = true
    @AppStorage(SubjectiveWindow.companionURLKey) private var goodNotesURL = SubjectiveWindow.defaultCompanionURL
    @AppStorage(SettingsKey.backupProtocol) private var backupProtocol = LLMProtocol.openAI.rawValue
    @AppStorage(SettingsKey.backupBaseURL) private var backupBaseURL = LLMProtocol.openAI.defaultBaseURL
    @AppStorage(SettingsKey.backupModel) private var backupModel = ""
    @AppStorage(SettingsKey.backupEffort) private var backupEffort = ""
    @State private var backupAPIKey = Keychain.read(account: "backupAPIKey") ?? ""
    @State private var confirmClearCache = false
    @State private var clearTarget: ClearTarget?
    @State private var clearResult: String?

    /// 要清除做题记录的节；section 为 nil 表示整本书
    private struct ClearTarget: Identifiable {
        let pack: StudyPack
        let section: SectionFile?
        var id: String { "\(pack.id)|\(section?.section.id ?? "*")" }
        var title: String { section.map { "\($0.section.id) \($0.section.title)" } ?? "《\(pack.title)》全部各节" }
    }
    @AppStorage("draft.enabled") private var draftEnabled = true
    @AppStorage(ReviewScheduler.retentionKey) private var retention = 0.9
    @AppStorage(ReviewScheduler.dailyMinutesKey) private var dailyMinutes = 30
    @AppStorage(PhraseDeck.dailyNewKey) private var phraseDailyNew = PhraseUnlock.defaultDailyNew
    @AppStorage("ink.scribbleErase") private var scribbleErase = true
    @AppStorage("ink.logEnabled") private var inkLogEnabled = true
    @State private var inkLogSize = InkLog.totalSize()
    @State private var activityLogSize = ActivityLog.totalSize()
    @State private var exporting = false
    @State private var exportError: String?
    @State private var archives: [URL] = []

    /// 安装包里的签名描述文件；模拟器上没有
    private static let signing = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { SigningProfile.parse($0) }

    private func exportData() {
        guard let storeURL = context.container.configurations.first?.url else { return }
        try? context.save()
        exporting = true
        exportError = nil
        Task {
            do {
                _ = try await Task.detached { try DataExport.export(storeURL: storeURL) }.value
            } catch {
                exportError = error.localizedDescription
            }
            archives = DataExport.archives()
            exporting = false
        }
    }

    @ViewBuilder private var driveSection: some View {
        Section {
            if drive.signedIn {
                LabeledContent("账号", value: drive.email ?? "已登录")
                Button(drive.step ?? "立即备份", systemImage: "icloud.and.arrow.up") {
                    Task { await drive.backup(in: context) }
                }
                .disabled(drive.busy)
                if let last = drive.lastSuccess {
                    LabeledContent("上次备份", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Button("退出登录", role: .destructive) { drive.signOut() }
                    .disabled(drive.busy)
            } else {
                Button(drive.step ?? "登录 Google Drive", systemImage: "person.crop.circle.badge.plus") { signInDrive() }
                    .disabled(drive.busy)
            }
            if let error = drive.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        } header: {
            Text("Google Drive")
        } footer: {
            Text("登录后每天第一次打开 App 时自动导出一份存档，上传到 Google Drive 的「\(GoogleDrive.folderName)」文件夹，保留最近 \(CloudBackup.keepCount) 份。App 只能访问自己建的文件。")
        }
    }

    private func signInDrive() {
        let url = drive.signInURL()
        Task {
            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: url, callback: .customScheme(GoogleDrive.callbackScheme), additionalHeaderFields: [:])
                await drive.completeSignIn(callback: callback, in: context)
            } catch {
                drive.signInFailed(error)
            }
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func clear(_ t: ClearTarget) {
        var attempts = 0, reviews = 0
        do {
            for s in t.section.map({ [$0] }) ?? t.pack.sections {
                let r = try RecordMaintenance.clearSection(packID: t.pack.id, sectionID: s.section.id,
                                                           questionIDs: s.questions.map(\.id),
                                                           subjectiveIDs: (s.subjective ?? []).map(\.id), in: context)
                attempts += r.attempts
                reviews += r.reviews
            }
            clearResult = "\(t.title)：删除了 \(attempts) 条作答记录、\(reviews) 道复习题，学习进度已重置。"
        } catch {
            clearResult = "清除失败：\(error.localizedDescription)"
        }
        clearTarget = nil
    }

    private var protocolValue: LLMProtocol { LLMProtocol(rawValue: proto) ?? .anthropic }
    private var backupProtocolValue: LLMProtocol { LLMProtocol(rawValue: backupProtocol) ?? .openAI }

    private var primaryConfig: LLMConfig {
        LLMConfig(proto: protocolValue, baseURL: baseURL, model: model,
                  apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), effort: effort, fallback: fallback)
    }
    private var backupConfig: LLMConfig {
        LLMConfig(proto: backupProtocolValue, baseURL: backupBaseURL, model: backupModel,
                  apiKey: backupAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                  effort: backupEffort, fallback: false, provider: .backup)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("接口类型", selection: $proto) {
                        ForEach(LLMProtocol.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .onChange(of: proto) { _, new in
                        let p = LLMProtocol(rawValue: new) ?? .anthropic
                        baseURL = p.defaultBaseURL
                        model = p.defaultModel
                    }
                    LabeledContent("Base URL") {
                        TextField(protocolValue.defaultBaseURL, text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("默认模型") {
                        TextField(protocolValue.defaultModel.isEmpty ? "例如 deepseek-chat" : protocolValue.defaultModel, text: $model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("API Key") {
                        SecureField("必填", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .onChange(of: apiKey) { _, v in Keychain.save(v.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    }
                    ProviderModelsRow(config: primaryConfig, models: $primaryModels, defaultModel: $model)
                } header: {
                    Text("主供应商")
                } footer: {
                    Text(protocolValue == .anthropic
                         ? "支持 HTTPS 和已放行的 HTTP 主机。请求地址为 Base URL + /v1/messages（Base URL 已以 /v1 结尾时只加 /messages）。API Key 保存在钥匙串中。"
                         : "支持 HTTPS 和已放行的 HTTP 主机。只填服务器地址时自动补 /v1/chat/completions；自定义前缀后加 /chat/completions，完整接口地址直接使用。API Key 保存在钥匙串中。")
                    if let url = LLMEndpoint.url(baseURL: baseURL, proto: protocolValue) {
                        Text("实际请求地址：\(LLMEndpoint.display(url))")
                    }
                    if let ats = Bundle.main.infoDictionary?["NSAppTransportSecurity"] as? [String: Any],
                       let hosts = ats["NSExceptionDomains"] as? [String: Any] {
                        Text("HTTP 已放行主机：\(hosts.keys.sorted().joined(separator: "、"))（可使用自定义端口）。")
                    }
                }

                if protocolValue == .anthropic {
                    Section {
                        Picker("思考强度", selection: $effort) {
                            Text("模型默认").tag("")
                            Text("low").tag("low")
                            Text("medium").tag("medium")
                            Text("high").tag("high")
                        }
                        Toggle("供应商内拒答时换模型", isOn: $fallback)
                    } header: {
                        Text("Anthropic 选项")
                    } footer: {
                        Text("默认 high。思考强度越低，讲解出得越快、越省。\n自动换用备用模型：Claude Opus 5 / Fable 系列的安全分类器偶尔会误拒正常请求，开启后由服务端自动换用推荐的备用模型重试（请求中附带 fallbacks: \"default\"）。使用第三方代理地址时如遇报错，可关闭此项。")
                    }
                }

                Section {
                    Toggle("启用备用供应商", isOn: $backupEnabled)
                    if backupEnabled {
                        Picker("接口类型", selection: $backupProtocol) {
                            ForEach(LLMProtocol.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .onChange(of: backupProtocol) { _, new in
                            let p = LLMProtocol(rawValue: new) ?? .openAI
                            backupBaseURL = p.defaultBaseURL
                            backupModel = p.defaultModel
                        }
                        LabeledContent("Base URL") {
                            TextField(backupProtocolValue.defaultBaseURL, text: $backupBaseURL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.URL).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("默认模型") {
                            TextField("备用模型", text: $backupModel)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("API Key") {
                            SecureField("必填", text: $backupAPIKey)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .onChange(of: backupAPIKey) { _, v in
                                    Keychain.save(v.trimmingCharacters(in: .whitespacesAndNewlines), account: "backupAPIKey")
                                }
                        }
                        ProviderModelsRow(config: backupConfig, models: $backupModels, defaultModel: $backupModel)
                        if backupProtocolValue == .anthropic {
                            Picker("思考强度", selection: $backupEffort) {
                                Text("模型默认").tag("")
                                Text("low").tag("low")
                                Text("medium").tag("medium")
                                Text("high").tag("high")
                            }
                        }
                    }
                } header: {
                    Text("备用供应商")
                } footer: {
                    Text("填写完整并启用后，所选模型请求报错、拒答或回答中断时，自动改用备用供应商的默认模型重新回答一次。手写批改需要模型支持图片。密钥单独保存在钥匙串中。")
                    if backupEnabled, let url = LLMEndpoint.url(baseURL: backupBaseURL, proto: backupProtocolValue) {
                        Text("实际请求地址：\(LLMEndpoint.display(url))")
                    }
                }

                Section {
                    ForEach(LLMPurpose.configurable) { purpose in
                        PurposeModelRow(purpose: purpose, primaryDefault: model, primaryModels: primaryModels,
                                        backupModels: backupModels, backupEnabled: backupEnabled)
                    }
                    if protocolValue == .anthropic {
                        Picker("讲解的思考强度", selection: $lectureEffort) {
                            Text("供应商默认").tag("")
                            Text("low").tag("low")
                            Text("medium").tag("medium")
                            Text("high").tag("high")
                        }
                    }
                } header: {
                    Text("细分模型")
                } footer: {
                    Text("留空使用主供应商默认模型。可手填模型名，或从供应商接口返回的列表中选择；从哪个供应商的列表选，就用该供应商的地址和密钥请求。填写模型后可添加回退模型：所选模型失败时依次改用，都失败再回退到备用供应商默认模型。手写批改及包含题目图片的请求需选择支持图片的模型。已有讲解和批改不会因更换模型自动重新生成。")
                }

                Section {
                    Button("测试主供应商", systemImage: "bolt.horizontal") {
                        let (system, messages) = Prompts.connectionTest
                        testRunner.run(system: system, messages: messages, backup: nil)
                    }
                    .disabled(testRunner.isRunning)
                    if backupEnabled {
                        Button("测试备用供应商", systemImage: "bolt.horizontal") {
                            guard let config = LLMConfig.backup() else { return }
                            let (system, messages) = Prompts.connectionTest
                            testRunner.run(system: system, messages: messages, config: config, backup: nil)
                        }
                        .disabled(testRunner.isRunning || LLMConfig.backup() == nil)
                    }
                    if testRunner.isRunning || testRunner.error != nil || !testRunner.text.isEmpty {
                        StreamStatusView(runner: testRunner)
                        if !testRunner.text.isEmpty {
                            Label("模型回复：\(testRunner.text)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section {
                    Picker("目标记住率", selection: $retention) {
                        Text("85%（复习少一些）").tag(0.85)
                        Text("90%（推荐）").tag(0.9)
                        Text("95%（复习多一些）").tag(0.95)
                    }
                    .onChange(of: retention) { ReviewScheduler.retune(in: context) }
                    Picker("每天复习时长", selection: $dailyMinutes) {
                        ForEach([15, 20, 30, 45, 60], id: \.self) { Text("\($0) 分钟").tag($0) }
                        Text("不限").tag(0)
                    }
                    Stepper("说法卡每天新卡 \(phraseDailyNew) 张", value: $phraseDailyNew, in: 0...40, step: 5)
                } header: {
                    Text("复习")
                } footer: {
                    Text("复习按 FSRS 记忆模型安排：在估计记得的概率降到这个值时复习。调高会更频繁地复习、记得更牢。做一遍要 2 分钟以上的题目标记住率按用时降低，15 分钟以上的低 10 个百分点（不低于 70%），间隔拉长。修改后重新安排全部题目。\n每天复习时长：按以往复习每道题的用时，从到期的题里挑出今天做的，其余顺延；到期的题不多时全部都做。\n说法卡每天新卡：学过的题考到的固定说法每天最多放进来几张，从第二天起生效；设为 0 不再放新卡。")
                }

                Section {
                    Toggle("草稿模式", isOn: $draftEnabled)
                    Toggle("涂抹即擦除", isOn: $scribbleErase)
                    Toggle("记录笔迹日志", isOn: $inkLogEnabled)
                    Toggle("主观题单独窗口作答时调出 GoodNotes", isOn: $openGoodNotes)
                    if openGoodNotes {
                        HStack {
                            TextField("调出 GoodNotes 的链接", text: $goodNotesURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                            Button("试一下") { SubjectiveWindow.shared.openCompanion() }
                                .buttonStyle(.bordered)
                        }
                    }
                    LabeledContent("日志大小", value: ByteCountFormatter.string(fromByteCount: Int64(inkLogSize), countStyle: .file))
                    if let latest = InkLog.logFiles().first {
                        ShareLink(item: latest) { Label("分享今天的笔迹日志", systemImage: "square.and.arrow.up") }
                    }
                    Button("清除笔迹日志", systemImage: "trash", role: .destructive) {
                        InkLog.clear()
                        inkLogSize = InkLog.totalSize()
                    }
                    LabeledContent("操作日志大小", value: ByteCountFormatter.string(fromByteCount: Int64(activityLogSize), countStyle: .file))
                    if let latest = ActivityLog.logFiles().first {
                        ShareLink(item: latest) { Label("分享今天的操作日志", systemImage: "square.and.arrow.up") }
                    }
                } header: {
                    Text("草稿与手写")
                } footer: {
                    Text("草稿模式下 Apple Pencil 可以在讲解页、题目页的任何地方写，页面改为双指滚动；手指的点按、长按选字不受影响。涂抹即擦除：用笔在已有笔迹上快速来回涂抹，抬笔后删除被涂到的笔画（移植自 Saber）。主观题点「单独窗口作答」时，可以同时调出 GoodNotes，回到它上次的位置。笔迹日志保存在「文件」App › LearningPack › InkLogs，保留 14 天。操作日志（学习过程：停留、AI 请求、状态标注等）保存在 ActivityLogs，一直保留。")
                }
                .onAppear {
                    inkLogSize = InkLog.totalSize()
                    activityLogSize = ActivityLog.totalSize()
                }

                Section {
                    if let info = Self.signing {
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            let status = SigningProfile.status(info, now: timeline.date)
                            LabeledContent("签名到期") {
                                Text(info.expires, format: .dateTime.month().day().weekday().hour().minute())
                                    + Text(status == .expired ? "（已过期）"
                                           : "（\(Text(info.expires, style: .relative))后）")
                            }
                            .foregroundStyle(status == .ok ? Color.primary : status == .soon ? .orange : .red)
                        }
                        LabeledContent("签名时间",
                                       value: info.created.formatted(.dateTime.month().day().hour().minute()))
                    } else {
                        LabeledContent("签名到期", value: "无描述文件（模拟器）")
                    }
                } header: {
                    Text("签名")
                } footer: {
                    Text("免费 Apple ID 签名 7 天有效，到期后 App 打不开。到期前用 Xcode 连接 iPad 重新运行一次即可续期；直接覆盖安装，不要先删除 App，否则数据会丢失。安装前先导出一份数据。")
                }

                // 手机额度已关闭
                /*
                Section {
                    LabeledContent("配对密钥") {
                        Text(pairingSecret)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("重新生成密钥", systemImage: "arrow.triangle.2.circlepath") { confirmNewSecret = true }
                        .confirmationDialog("重新生成后，手机上要重新填密钥，旧密钥算出的学习码不再有效。", isPresented: $confirmNewSecret,
                                            titleVisibility: .visible) {
                            Button("重新生成", role: .destructive) {
                                stateCheck.regenerateSecret()
                                pairingSecret = stateCheck.pairingSecret
                            }
                        }
                } header: {
                    Text("手机额度")
                } footer: {
                    Text("学习可以换成手机的使用时间：在手机「时间记录」里填一次这个密钥，之后在工具栏「状态」›「手机学习码」查看今天的学习分钟、开始次数和校验码，输入到手机上。")
                }
                .onAppear { pairingSecret = stateCheck.pairingSecret }
                */


                Section {
                    Button(exporting ? "正在导出…" : "导出数据", systemImage: "archivebox") { exportData() }
                        .disabled(exporting)
                    if let exportError {
                        Label(exportError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    ForEach(archives, id: \.self) { url in
                        ShareLink(item: url) {
                            LabeledContent(url.deletingPathExtension().lastPathComponent,
                                           value: ByteCountFormatter.string(fromByteCount: fileSize(url), countStyle: .file))
                        }
                    }
                } header: {
                    Text("备份")
                } footer: {
                    Text("把作答记录、复习安排、讲解缓存、草稿、主观题笔迹记录、笔迹日志、操作日志和设置打包成一个 zip，存在「文件」App › LearningPack › Backups（保留最近 5 份），点按可分享。教辅包和 API Key 不在其中。Mac 上推送教辅包（deploy.sh）前会自动导出一份并上传到 Google Drive。")
                }
                .onAppear { archives = DataExport.archives() }
                .onChange(of: drive.lastSuccess) { archives = DataExport.archives() }

                driveSection

                PhoneSyncSection()

                WebAccessSection()

                Section {
                    ForEach(store.packs) { pack in
                        LabeledContent(pack.title, value: "\(pack.sections.count) 节 · \(pack.questions.count) 题")
                    }
                    Button("清除 AI 讲解缓存", systemImage: "trash", role: .destructive) { confirmClearCache = true }
                } header: {
                    Text("数据")
                } footer: {
                    Text("教辅包存放在「文件」App › 我的 iPad › LearningPack。删除或替换教辅包不会影响作答记录。")
                }

                Section {
                    ForEach(store.packs) { pack in
                        ForEach(pack.sections, id: \.section.id) { s in
                            Button("清除 \(s.section.id) \(s.section.title) 的做题记录", systemImage: "trash",
                                   role: .destructive) {
                                clearTarget = ClearTarget(pack: pack, section: s)
                            }
                        }
                        Button("清除《\(pack.title)》全部做题记录", systemImage: "trash.fill", role: .destructive) {
                            clearTarget = ClearTarget(pack: pack, section: nil)
                        }
                    }
                } header: {
                    Text("测试")
                } footer: {
                    Text("清除某节的作答记录、复习队列、学习进度，以及主观题的书写和笔迹记录，便于从头测试。AI 讲解和其他页面的草稿不受影响。")
                }

            }
            .navigationTitle("设置")
            .confirmationDialog("清除\(clearTarget?.title ?? "")的做题记录？",
                                isPresented: Binding(get: { clearTarget != nil }, set: { if !$0 { clearTarget = nil } }),
                                titleVisibility: .visible, presenting: clearTarget) { t in
                Button("清除", role: .destructive) { clear(t) }
            } message: { _ in
                Text("删除作答记录、复习队列、学习进度（回到第 1 轮）和主观题书写，无法恢复。AI 讲解和其他草稿保留。")
            }
            .alert("已清除", isPresented: Binding(get: { clearResult != nil }, set: { if !$0 { clearResult = nil } })) {
                Button("好") { clearResult = nil }
            } message: {
                Text(clearResult ?? "")
            }
            .confirmationDialog("清除所有已缓存的 AI 讲解？下次打开时会重新生成。", isPresented: $confirmClearCache,
                                titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    try? context.delete(model: LectureCache.self)
                    try? context.save()
                }
            }
        }
    }
}
