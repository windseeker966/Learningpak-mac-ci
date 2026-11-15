import Foundation
import Observation
import SwiftData

/// 一轮讲解的缓存键与提示词。讲解页（逐轮流式生成）和批量生成共用。
enum LectureGeneration {
    static func cacheKey(pack: StudyPack, section: SectionFile, round: Round) -> String {
        "\(pack.id)|\(section.section.id)|round\(round.num)"
    }

    /// 新知识轮用讲解提示词，巩固轮用回顾提示词
    static func messages(pack: StudyPack, section: SectionFile, round: Round) -> (String, [ChatTurn]) {
        let isRecap = round.chunks.isEmpty
        let chunks = (isRecap ? round.recap?.from ?? [] : round.chunks).compactMap { pack.chunks[$0] }
        if isRecap {
            return Prompts.recap(pack: pack, section: section, topic: round.recap?.topic ?? "",
                                 chunks: chunks)
        }
        // 本节中排在本轮之前、已经讲过的知识块标题
        let learned = section.rounds.prefix { $0.num != round.num }
            .flatMap(\.chunks)
            .compactMap { pack.chunks[$0]?.title }
        return Prompts.lecture(pack: pack, section: section, chunks: chunks,
                               learnedTitles: learned,
                               preceding: precedingChunk(pack: pack, section: section, round: round))
    }

    /// 本节中紧挨在本轮之前讲过的知识块。本轮原文常用编号引用它的内容（如「产生式(3)(4)」对应的文法在上一块），
    /// 随讲解和追问一起发给 AI 查对；巩固轮没有
    static func precedingChunk(pack: StudyPack, section: SectionFile, round: Round) -> Chunk? {
        guard !round.chunks.isEmpty else { return nil }
        return section.rounds.prefix { $0.num != round.num }
            .flatMap(\.chunks).last
            .flatMap { pack.chunks[$0] }
    }

    /// 批量生成时这一轮不用再生成：有当前提示词版本的讲解；或是旧版，但这一轮已经学过（done 里有本轮的题）
    /// 或讲解页上写了草稿（换掉讲解会删掉草稿）。还没学到的旧版讲解换成新版，打开时不用再点「重新生成」
    static func isReady(version: Int?, studied: Bool, hasDraft: Bool) -> Bool {
        guard let version else { return false }
        return version >= Prompts.lectureVersion || studied || hasDraft
    }

    static func isReady(pack: StudyPack, section: SectionFile, round: Round, done: Set<String>,
                        in context: ModelContext) -> Bool {
        let key = cacheKey(pack: pack, section: section, round: round)
        let version = (try? context.fetch(FetchDescriptor<LectureCache>(predicate: #Predicate { $0.key == key })))?
            .first?.promptVersion
        let draftKey = DraftKey.lecture(pack: pack.id, section: section.section.id, round: round.num)
        let hasDraft = ((try? context.fetchCount(FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key == draftKey }))) ?? 0) > 0
        return isReady(version: version, studied: round.questions.contains(where: done.contains), hasDraft: hasDraft)
    }

    /// 书库页显示用：一本书里各轮讲解的提示词版本，和讲解页上写了草稿的轮次（都按讲解的缓存键）
    static func cacheState(packID: String, in context: ModelContext) -> (versions: [String: Int], drafted: Set<String>) {
        let prefix = "\(packID)|"
        var d = FetchDescriptor<LectureCache>(predicate: #Predicate { $0.key.starts(with: prefix) })
        d.propertiesToFetch = [\.key, \.promptVersion]
        let versions = Dictionary(((try? context.fetch(d)) ?? []).map { ($0.key, $0.promptVersion) },
                                  uniquingKeysWith: { a, _ in a })
        var drafts = FetchDescriptor<DraftInk>(predicate: #Predicate { $0.key.starts(with: prefix) })
        drafts.propertiesToFetch = [\.key]
        let suffix = "|lecture"
        let drafted = Set(((try? context.fetch(drafts)) ?? []).map(\.key)
            .filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
        return (versions, drafted)
    }
}

/// 一键生成一节所有轮次的 AI 讲解：并发生成缺失的各轮讲解，还没学到的旧版讲解也换成新版（见 LectureGeneration.isReady），并记录进度。
/// 放在 App 层，离开书库页、进入某一节时生成照常进行。
@MainActor
@Observable
final class LectureBatch {
    struct Job {
        var total: Int
        var done = 0
        var failed = 0
        var finished = false
        var lastError: String?
    }

    private(set) var jobs: [String: Job] = [:]
    /// 每完成一轮加一，讲解页据此重新读取缓存
    private(set) var version = 0
    /// 批量任务中尚未完成的讲解缓存键
    private var pending: Set<String> = []
    /// 讲解页正在自行生成的缓存键，批量任务跳过它们
    private var interactive: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]

    /// 每节同时生成几轮
    private static let concurrency = 3
    /// 多节一起生成时，所有节合计同时请求的上限；超出的轮次排队，先到先得
    private static let limiter = ConcurrencyLimiter(limit: 5)

    static func jobKey(pack: StudyPack, section: SectionFile) -> String { "\(pack.id)|\(section.section.id)" }

    func job(pack: StudyPack, section: SectionFile) -> Job? { jobs[Self.jobKey(pack: pack, section: section)] }

    func isRunning(pack: StudyPack, section: SectionFile) -> Bool {
        tasks[Self.jobKey(pack: pack, section: section)] != nil
    }

    /// 这一轮的讲解是否在批量任务里排队或正在生成
    func isPending(_ cacheKey: String) -> Bool { pending.contains(cacheKey) }

    func beginInteractive(_ cacheKey: String) { interactive.insert(cacheKey) }
    func endInteractive(_ cacheKey: String) { interactive.remove(cacheKey) }

    /// 本节要生成讲解的轮次：没有讲解，或是还没学到的旧版（阅读轮、习题轮不讲解）。done 是做过的题
    func missingRounds(pack: StudyPack, section: SectionFile, done: Set<String>, in context: ModelContext) -> [Round] {
        section.rounds.filter {
            !$0.skipsLecture(in: pack) && !LectureGeneration.isReady(pack: pack, section: section, round: $0, done: done, in: context)
        }
    }

    /// done 是做过的题（学过的轮次不换旧版讲解）；useBackup：改用备用供应商的默认模型（不再回退）
    func start(pack: StudyPack, section: SectionFile, done: Set<String>, context: ModelContext, useBackup: Bool = false) {
        let key = Self.jobKey(pack: pack, section: section)
        guard tasks[key] == nil else { return }
        let rounds = missingRounds(pack: pack, section: section, done: done, in: context)
        guard !rounds.isEmpty else { return }
        let keys = rounds.map { LectureGeneration.cacheKey(pack: pack, section: section, round: $0) }
        pending.formUnion(keys)
        jobs[key] = Job(total: rounds.count)
        ActivityLog.write("lecture_batch_start", ["section": key, "rounds": rounds.map(\.num)])

        tasks[key] = Task { [weak self] in
            await self?.run(key: key, pack: pack, section: section, rounds: rounds, done: done, context: context,
                            backup: useBackup ? LLMConfig.backup() : nil)
            guard let self else { return }
            self.pending.subtract(keys)
            self.tasks[key] = nil
            self.jobs[key]?.finished = true
            self.version += 1
            ActivityLog.write("lecture_batch_end", ["section": key, "done": self.jobs[key]?.done ?? 0,
                                               "failed": self.jobs[key]?.failed ?? 0])
        }
    }

    func cancel(pack: StudyPack, section: SectionFile) {
        tasks[Self.jobKey(pack: pack, section: section)]?.cancel()
    }

    /// 通知所有已打开的轮次重新读取本节讲解。
    func sectionContentChanged() { version += 1 }

    private func run(key: String, pack: StudyPack, section: SectionFile, rounds: [Round], done: Set<String>,
                     context: ModelContext, backup: LLMConfig?) async {
        func client(_ purpose: LLMPurpose, round: Round) -> LLMClient {
            let sink = ActivityLog.llmSink(["section": key, "round": round.num, "purpose": purpose.rawValue, "batch": true])
            return backup.map { LLMClient(config: $0, backup: nil, diagnostics: sink) }
                ?? LLMClient(config: .current(purpose), diagnostics: sink)
        }
        if Task.isCancelled { return }

        var queue = rounds[...]
        await withTaskGroup(of: (Round, Result<LLMCompletion, Error>).self) { group in
            // 先放满并发数，之后每完成一轮再补一轮
            var slots = Self.concurrency
            while true {
                while slots > 0, !Task.isCancelled,
                      let (round, system, messages) = nextRound(from: &queue, key: key, pack: pack, section: section,
                                                                 done: done, context: context) {
                    slots -= 1
                    let llm = client(round.chunks.isEmpty ? .recap : .lecture, round: round)
                    group.addTask {
                        // 在子任务里排队等全局空位，主循环照常收已完成的轮次
                        guard await Self.limiter.acquire() else { return (round, .failure(CancellationError())) }
                        let result: Result<LLMCompletion, Error>
                        do {
                            result = .success(try await llm.complete(system: system, messages: messages))
                        } catch {
                            result = .failure(error)
                        }
                        await Self.limiter.release()
                        return (round, result)
                    }
                }
                guard let (round, result) = await group.next() else { break }
                slots += 1
                finish(round: round, result: result, key: key, pack: pack, section: section,
                       done: done, context: context)
            }
        }
    }

    /// 取下一轮要生成的讲解；讲解页已在生成或已经不用生成（见 LectureGeneration.isReady）的轮次直接算作完成
    private func nextRound(from queue: inout ArraySlice<Round>, key: String, pack: StudyPack, section: SectionFile,
                           done: Set<String>, context: ModelContext) -> (Round, String, [ChatTurn])? {
        while let round = queue.popFirst() {
            let cacheKey = LectureGeneration.cacheKey(pack: pack, section: section, round: round)
            if interactive.contains(cacheKey)
                || LectureGeneration.isReady(pack: pack, section: section, round: round, done: done, in: context) {
                pending.remove(cacheKey)
                jobs[key]?.done += 1
                version += 1
                continue
            }
            let (system, messages) = LectureGeneration.messages(pack: pack, section: section, round: round)
            return (round, system, messages)
        }
        return nil
    }

    private func finish(round: Round, result: Result<LLMCompletion, Error>, key: String, pack: StudyPack,
                        section: SectionFile, done: Set<String>, context: ModelContext) {
        let cacheKey = LectureGeneration.cacheKey(pack: pack, section: section, round: round)
        switch result {
        case .success(let answer) where !answer.text.isEmpty && !Task.isCancelled:
            // 生成期间讲解页可能已经生成了新版、或在讲解上写了草稿：这时留着原来的
            if !LectureGeneration.isReady(pack: pack, section: section, round: round, done: done, in: context) {
                let old = (try? context.fetch(FetchDescriptor<LectureCache>(predicate: #Predicate { $0.key == cacheKey }))) ?? []
                old.forEach(context.delete)
                context.insert(LectureCache(key: cacheKey, text: answer.text, model: answer.usage.model,
                                            promptVersion: Prompts.lectureVersion, usage: answer.usage))
                try? context.save()
            }
            jobs[key]?.done += 1
        case .success:
            jobs[key]?.failed += 1
            ActivityLog.write("lecture_round_failure", ["section": key, "round": round.num,
                                                   "error": Task.isCancelled ? "cancelled" : "empty_response"])
        case .failure(let error):
            jobs[key]?.failed += 1
            jobs[key]?.lastError = error.localizedDescription
            ActivityLog.write("lecture_round_failure", ["section": key, "round": round.num,
                                                   "error": error.localizedDescription])
        }
        pending.remove(cacheKey)
        version += 1
    }
}
