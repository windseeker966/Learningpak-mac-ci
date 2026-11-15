import Foundation
import Observation
import SwiftData

/// 一轮讲解：读缓存或流式生成 AI 讲解、等「生成本节讲解」的后台任务、重新生成后存缓存，以及下方的追问对话。
/// 主窗口和单独窗口共用同一个（见 DetachableLecture）：转过去、转回来时讲解接着生成，追问也还在。
@MainActor @Observable
final class LectureSession {
    let pack: StudyPack
    let section: SectionFile
    let round: Round
    let runner = StreamRunner()
    let chat = ChatSession()
    private(set) var cachedText: String?
    private(set) var cachedUsage: LLMUsage?
    private(set) var cachedModel: String?
    private(set) var cachedVersion = Prompts.lectureVersion
    @ObservationIgnored private var generationID = UUID()
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var batch: LectureBatch?

    init(pack: StudyPack, section: SectionFile, round: Round) {
        self.pack = pack
        self.section = section
        self.round = round
    }

    var isRecap: Bool { round.chunks.isEmpty }
    var chunks: [Chunk] {
        (isRecap ? round.recap?.from ?? [] : round.chunks).compactMap { pack.chunks[$0] }
    }
    var cacheKey: String { LectureGeneration.cacheKey(pack: pack, section: section, round: round) }
    var configured: Bool { LLMConfig.hasAvailableProvider(isRecap ? .recap : .lecture) }
    var lectureText: String { cachedText ?? runner.text }
    /// 本轮讲解正在「生成本节讲解」的后台任务里排队或生成
    var waitingForBatch: Bool { cachedText == nil && !runner.isRunning && (batch?.isPending(cacheKey) ?? false) }

    /// 讲解页出现时调用：读缓存，没有就等后台任务或自己生成。另一个窗口里已经开始的，接着用。
    /// 返回 false 表示没有讲解可看（没配置模型），讲解页改为显示原文
    @discardableResult
    func load(context: ModelContext, batch: LectureBatch) -> Bool {
        let first = self.context == nil
        self.context = context
        self.batch = batch
        guard first else { return true }
        chat.system = Prompts.followUpSystem(
            pack: pack, chunks: chunks,
            preceding: LectureGeneration.precedingChunk(pack: pack, section: section, round: round))
        #if DEBUG
        // 调试：启动参数 -debugLecture "<markdown>" 用给定文本代替 AI 讲解
        if let fake = UserDefaults.standard.string(forKey: "debugLecture") {
            cachedText = fake.replacingOccurrences(of: "\\n", with: "\n")
            return true
        }
        #endif
        if loadCache() || batch.isPending(cacheKey) { return true }  // 后台任务会生成，完成后在 batchProgressed 里读取
        guard configured else { return false }
        generate()
        return true
    }

    @discardableResult
    private func loadCache() -> Bool {
        let key = cacheKey
        guard let hit = try? context?.fetch(FetchDescriptor<LectureCache>(predicate: #Predicate { $0.key == key })).first
        else { return false }
        cachedText = hit.text
        cachedUsage = hit.usage
        cachedModel = hit.model
        cachedVersion = hit.promptVersion
        updateChatContext()
        return true
    }

    /// 批量任务有进展：可能刚生成了本轮讲解
    func batchProgressed() {
        guard !runner.isRunning, let batch else { return }
        if cachedText != nil {
            // 打开的是旧版讲解，批量任务可能刚把它换成了新版
            if cachedVersion < Prompts.lectureVersion { loadCache() }
            return
        }
        if loadCache() { return }
        // 批量任务结束了却没生成出本轮（失败或取消）：改为在这里生成
        if !batch.isPending(cacheKey) && configured && runner.error == nil { generate() }
    }

    /// useBackup：改用备用供应商的默认模型（不再回退）
    func generate(useBackup: Bool = false) {
        let id = UUID()
        generationID = id
        runner.cancel()
        runner.text = ""
        cachedText = nil
        runner.error = nil
        let backup = useBackup ? LLMConfig.backup() : nil
        let config = backup ?? LLMConfig.current(isRecap ? .recap : .lecture)
        let key = cacheKey
        batch?.beginInteractive(key)
        let (system, messages) = LectureGeneration.messages(pack: pack, section: section, round: round)
        let logContext: [String: Any] = ["section": "\(pack.id)|\(section.section.id)", "round": round.num,
                                         "purpose": (isRecap ? LLMPurpose.recap : .lecture).rawValue]
        // 离开讲解页后（本对象可能已释放）生成完也照常存缓存
        let (context, pack, section, round) = (self.context, pack, section, round)
        runner.run(system: system, messages: messages, config: config, backup: backup == nil ? .backup() : nil,
                   diagnostics: ActivityLog.llmSink(logContext), onFinish: { [weak self, weak runner, batch] text in
            batch?.endInteractive(key)
            guard self.map({ $0.generationID == id }) ?? true, !text.isEmpty, let context else { return }
            let model = runner?.usage?.model ?? config.model
            LectureSession.save(text: text, model: model, usage: runner?.usage,
                      pack: pack, section: section, round: round, in: context)
            guard let self else { return }
            // 生成完即视为已缓存：显示「重新生成」等按钮，不必切走再回来
            cachedText = text
            cachedUsage = runner?.usage
            cachedModel = model
            cachedVersion = Prompts.lectureVersion
            updateChatContext()
        })
    }

    /// 流式生成停了：出错或被取消时不会走完成回调，这里兜底撤销「讲解页正在生成」的登记
    func runnerStopped() {
        batch?.endInteractive(cacheKey)
    }

    /// 离开讲解页：还在生成的接着生成，生成完照常存缓存
    func leave() {
        if !runner.isRunning { batch?.endInteractive(cacheKey) }
    }

    /// 点「开始做题」：不再生成
    func cancel() {
        runner.cancel()
    }

    private static func save(text: String, model: String, usage: LLMUsage?,
                             pack: StudyPack, section: SectionFile, round: Round, in context: ModelContext) {
        let key = LectureGeneration.cacheKey(pack: pack, section: section, round: round)
        let fetch = FetchDescriptor<LectureCache>(predicate: #Predicate { $0.key == key })
        if let old = try? context.fetch(fetch).first {
            context.delete(old)
            // 讲解重新生成：这一页的旧草稿对不上新内容，直接删掉
            DraftStore.delete(DraftKey.lecture(pack: pack.id, section: section.section.id, round: round.num),
                              reason: "lecture_regenerated", in: context)
        }
        context.insert(LectureCache(key: key, text: text, model: model, promptVersion: Prompts.lectureVersion, usage: usage))
        try? context.save()
    }

    /// 追问时把讲解作为对话的前置上下文
    private func updateChatContext() {
        guard !runner.isRunning, !lectureText.isEmpty else { return }
        chat.context = [ChatTurn(role: .user, text: "请讲解本轮内容。"),
                        ChatTurn(role: .assistant, text: lectureText)]
    }
}
