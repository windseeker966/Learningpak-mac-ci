import Foundation
import SwiftData

/// AI 改编复习：在原题上改编出一道新题，针对学生做这题时的错误。
/// 变式题的 id 为「原题 id~ai-xxxx」，不在教辅包里；书写只在内存里，结果另记一条 VariantAttempt，按原题的规则计入原题的复习安排。
enum QuestionVariant {
    struct Generated {
        let question: Question
        /// 模型返回的原始 JSON，随记录保存
        let json: String
        let usage: LLMUsage?
    }

    enum VariantError: LocalizedError {
        case noJSON
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .noJSON: "模型没有返回题目 JSON。"
            case .invalid(let s): "模型返回的题目不完整：\(s)"
            }
        }
    }

    /// 变式题的 id 前缀：原题 id + "~ai-"
    static func isVariant(_ id: String) -> Bool { id.contains("~ai-") }
    static func originalID(of id: String) -> String { id.components(separatedBy: "~ai-").first ?? id }
    /// 新改编出的题的 id
    static func newID(originalID: String) -> String { "\(originalID)~ai-\(UUID().uuidString.prefix(8).lowercased())" }

    /// 生成一道变式题；格式不合格时重试一次
    @MainActor
    static func generate(pack: StudyPack, original q: Question, attempts: [AttemptRecord],
                         variants: [VariantAttempt] = [], faults: [String: QuestionMark] = [:],
                         useBackup: Bool = false) async throws -> Generated {
        let (system, messages) = prompt(pack: pack, question: q, attempts: attempts, variants: variants, faults: faults)
        let log = LogContext(question: q.id, purpose: .choiceVariant)
        var lastError: Error = VariantError.noJSON
        for round in 0..<2 {
            let (text, usage) = try await complete(system: system, messages: messages, purpose: .choiceVariant,
                                                   useBackup: useBackup, log: log.fields(round: round))
            do {
                let (question, json) = try parse(text, original: q)
                return Generated(question: question, json: json, usage: usage)
            } catch {
                lastError = error
                log.parseFailure(error, round: round, textChars: text.count)
            }
        }
        throw lastError
    }

    /// 调用对应改编用途的模型并收集完整回答。useBackup：改用备用供应商的默认模型，不再回退
    @MainActor
    private static func complete(system: String, messages: [ChatTurn], purpose: LLMPurpose,
                                 useBackup: Bool, log: [String: Any]) async throws -> (String, LLMUsage?) {
        var text = ""
        let backup = useBackup ? LLMConfig.backup() : nil
        let config = backup ?? LLMConfig.current(purpose)
        var usage: LLMUsage? = LLMUsage(model: config.model, provider: URL(string: config.baseURL)?.host ?? "供应商",
                                        isBackup: config.provider == .backup)
        for try await event in LLMClient(config: config, backup: backup == nil ? .backup() : nil,
                                         diagnostics: ActivityLog.llmSink(log))
            .stream(system: system, messages: messages) {
            switch event {
            case .started(let source): text = ""; usage = source
            case .model(let model): usage?.report(model: model, afterText: !text.isEmpty)
            case .text(let piece): text += piece
            case .stopped(let reason): usage?.finishReason = reason
            }
        }
        return (text, usage)
    }

    /// 一次改编在操作日志里的关联字段：同一次改编（含格式不合格后的重试）共用 variant_id
    private struct LogContext {
        let question: String
        let purpose: LLMPurpose
        let id = UUID().uuidString

        func fields(round: Int) -> [String: Any] {
            ["question": question, "purpose": purpose.rawValue, "variant_id": id, "variant_try": round]
        }

        func parseFailure(_ error: Error, round: Int, textChars: Int) {
            ActivityLog.write("ai_variant_parse_failure", fields(round: round).merging(
                ["error": error.localizedDescription, "text_chars": textChars]) { _, new in new })
        }
    }

    // MARK: - 存下的改编题

    /// 存下的选择改编题（PendingVariant）还原成改编结果；内容不合格时为 nil
    static func restore(_ p: PendingVariant, original: Question) -> Generated? {
        guard let text = String(data: p.content, encoding: .utf8),
              let (question, json) = try? parse(text, original: original, id: p.variantID) else { return nil }
        return Generated(question: question, json: json, usage: p.usage)
    }

    /// 存下的主观改编题还原成改编结果
    static func restoreSubjective(_ p: PendingVariant) -> SubjectiveGenerated? {
        guard let obj = (try? JSONSerialization.jsonObject(with: p.content)) as? [String: Any],
              let stem = obj["stem"] as? String, let answer = obj["answer"] as? String else { return nil }
        let parts = (obj["part_labels"] as? [String]) ?? ["全题"]
        return SubjectiveGenerated(stem: stem, answer: answer, parts: parts.isEmpty ? ["全题"] : parts,
                                   accepts: obj["accepts"] as? [[String]], usage: p.usage)
    }

    // MARK: - 同一知识点的原书题

    /// 同一主考知识点的其他原书题（不含 AI 出的、作废的、阅读题），按题号取前几道：给 AI 作出题风格和难度的参照
    static func peerQuestions(pack: StudyPack, of q: Question, limit: Int = 4) -> [Question] {
        guard let t = q.tests else { return [] }
        return Array(pack.questions.values
            .filter { $0.id != q.id && $0.tests == t && $0.deprecated != true && !$0.aiAuthored && $0.passage == nil }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            .prefix(limit))
    }

    static func peerQuestions(pack: StudyPack, of q: SubjectiveQuestion, limit: Int = 3) -> [SubjectiveQuestion] {
        guard let t = q.tests else { return [] }
        return Array(pack.subjective.values
            .filter { $0.id != q.id && $0.tests == t && $0.deprecated != true && $0.aiAuthored != true
                && $0.isBlank == q.isBlank && $0.stemForAI != nil }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            .prefix(limit))
    }

    /// 一道参照题：题干、选项、答案
    private static func peerText(_ p: Question) -> String {
        var t = "- \(p.stem)\n"
        for k in p.statementKeys { t += "  \(Roman.glyph(k)). \(p.statements?[k]?.text ?? "")\n" }
        for k in p.optionKeys {
            if p.type == .combo {
                t += "  \(k). " + (p.comboOptions?[k] ?? []).map(Roman.glyph).joined(separator: "、") + "\n"
            } else if let o = p.options?[k] ?? p.sharedOptions?[k] {
                t += "  \(k). \(o)\n"
            }
        }
        if let a = p.answer { t += "  答案：\(a)\n" }
        return t
    }

    /// 取出回答里的 JSON 对象；模型常犯的小错（对象或数组末尾多一个逗号）先修正再解析
    static func jsonObject(in text: String) -> (json: String, object: [String: Any])? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let json = String(text[start...end])
        if let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] { return (json, obj) }
        let fixed = json.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if let obj = (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) as? [String: Any] { return (fixed, obj) }
        return nil
    }

    // MARK: - 主观题

    struct SubjectiveGenerated {
        let stem: String
        let answer: String
        /// 小问编号（与题面一致）；不分小问时为 ["全题"]
        let parts: [String]
        /// 填空题各空可接受的答案（与 parts 一一对应，第一项是标准答案）；不是填空题或没给全时为 nil
        var accepts: [[String]]? = nil
        let usage: LLMUsage?

        /// 原题是键盘输入的填空题，且每空都有可接受的答案时，改编题也用键盘输入
        func typed(_ original: SubjectiveQuestion) -> Bool { original.typed && accepts != nil }

        /// 存进 VariantAttempt.content 的完整内容（JSON）
        var content: Data? {
            var dict: [String: Any] = ["stem": stem, "answer": answer, "part_labels": parts]
            if let accepts { dict["accepts"] = accepts }
            return try? JSONSerialization.data(withJSONObject: dict)
        }

        /// 当作一道主观题，交给原题的作答流程（SubjectiveAttemptSession）
        func question(from original: SubjectiveQuestion) -> SubjectiveQuestion {
            SubjectiveQuestion(
                id: original.id + "~ai", num: original.num, page: original.page, answerPage: nil,
                stem: stem, questionImage: nil, answer: answer, answerImages: nil, requires: original.requires,
                aiAuthored: true, aiWritten: nil, tests: original.tests, alsoTests: original.alsoTests,
                parts: parts.enumerated().map { i, label in
                    let accept = accepts?[i]
                    return SubjectiveQuestion.Part(label: label, answer: accept?.first, tests: nil, alsoTests: nil,
                                                   points: nil, accept: accept)
                },
                deprecated: nil, format: original.format, input: typed(original) ? "text" : nil)
        }
    }

    /// 改编一道主观题：题面 + 参考答案。参考以往每次作答的把握程度、自评、错误类型和 AI 批改
    @MainActor
    static func generateSubjective(pack: StudyPack, original q: SubjectiveQuestion, attempts: [SubjectiveAttempt],
                                   variants: [VariantAttempt] = [], faults: [String: QuestionMark] = [:],
                                   useBackup: Bool = false) async throws -> SubjectiveGenerated {
        let (system, messages) = subjectivePrompt(pack: pack, question: q, attempts: attempts, variants: variants,
                                                  faults: faults)
        let log = LogContext(question: q.id, purpose: .subjectiveVariant)
        var lastError: Error = VariantError.noJSON
        for round in 0..<2 {
            let (text, usage) = try await complete(system: system, messages: messages, purpose: .subjectiveVariant,
                                                   useBackup: useBackup, log: log.fields(round: round))
            guard let obj = jsonObject(in: text)?.object else {
                lastError = VariantError.noJSON
                log.parseFailure(lastError, round: round, textChars: text.count)
                continue
            }
            guard let stem = obj["stem"] as? String, !stem.isEmpty,
                  let answer = obj["answer"] as? String, !answer.isEmpty else {
                lastError = VariantError.invalid("缺少题面或参考答案")
                log.parseFailure(lastError, round: round, textChars: text.count)
                continue
            }
            let labels = ((obj["parts"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let parts = labels.isEmpty ? ["全题"] : labels
            let accepts = ((obj["accept"] as? [Any]) ?? []).map { item in
                ((item as? [Any]) ?? [item]).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            let complete = accepts.count == parts.count && accepts.allSatisfy { !$0.isEmpty }
            return SubjectiveGenerated(stem: stem, answer: answer, parts: parts,
                                       accepts: q.isBlank && complete ? accepts : nil, usage: usage)
        }
        throw lastError
    }

    static func subjectivePrompt(pack: StudyPack, question q: SubjectiveQuestion, attempts: [SubjectiveAttempt],
                                 variants: [VariantAttempt] = [],
                                 faults: [String: QuestionMark] = [:]) -> (String, [ChatTurn]) {
        let hasImages = q.questionImage != nil || !(q.answerImages ?? []).isEmpty
        // 图都有逐字转写时只发文字：不能看图的模型也能改编
        let sendImages = hasImages && !q.transcribed
        let system = """
        你是《\(pack.title)》的出题老师，正在为学生准备一道复习用的\(q.isBlank ? "填空题" : "主观题（综合应用题）")。给你一道学生做过的原题、它的参考答案、考查的知识点、同一知识点的其他原书题、出题依据的资料原文，以及学生以往做这道题的记录（每次看答案前的把握程度、对照答案后逐问的自评、错误类型和原因、订正笔记、AI 批改的结果，批改里有学生手写作答的转写和问题分析）和以往改编题的结果。\(sendImages ? "原题或答案是图片时，图片附在消息里，依次为原题图、答案图。" : hasImages ? "原题和答案原本是\(pack.sourceLabel)的图片，这里给的是逐字转写。" : "")

        请在原题基础上改编出一道新题：
        1. 先找出原题的关键判断点：做对这道题必须想清楚的那一点或必须会的那几步方法（如“页面置换要先判断是否命中，再按算法选出被换出的页”），而不是笼统的知识点。新题必须仍然考这些，不能换去考同一知识点下的其他内容。重点针对学生以往自评没做对的小问、错误类型和批改中暴露出的薄弱步骤；没有记录时，换一个角度考同样的方法。
        2. 不能只是同义改写，要让学生不能照抄原题答案。改编方式（推荐前两种）：
           - 平级改编：换数据、换例子、换场景（如换一个正则表达式、换一个文法、换一组进程参数），解题方法和步骤与原题相同。这是最稳妥的做法，推荐。
           - 给一个具体的错误做法或错误结果（如一段有错的代码、一个算错的结果），让学生指出错在哪里并改正。
           - 改变所求（如原题给 A 求 B，新题给 B 求 A），所用方法仍是原题的方法。
           要避免：
           - 不能变简单、变抽象：原题要求动手推导、计算、写代码或画图的，新题也要动手，不能改成背概念或问定义。原题本身是问概念、作用、组成的问答题时，改成一个小的应用：给一个具体例子，让学生判断、分类或写出其中一项，题量仍与原题相当。
           - 原题的核心材料（数据、文法、表达式、代码、例子）不能原样照搬，要改动到结果随之改变；也不要直接搬用资料原文或原题解析里现成的例子。
           - 新题的答案不能是资料原文里已经直接写出的内容（如原文已给出的某个正则表达式、某个例题的结果），要让学生用原文的方法自己推导出来。
        3. 难度和题量与原题相当：小问数、计算量、作答时间与原题接近；不要为了说清新情形补充大段规则说明，不增加步骤。
           题面不能透露答案：不要在题面里写出答案要用的关键条件或结论（如把某种模型的适用条件原样写进场景描述）。
           【同一知识点的其他原书题】展示了这本书的出题风格和难度，新题要与它们相当。
        4. 知识只能来自提供的资料原文和原题答案，不补充原文以外的知识；题目必须能用原文讲过的方法解出，答案唯一或标准明确。数据要先自己算通，保证有解、结果整齐；换了数据后检查原来的做法是否仍然成立（如条件变了会不会多出边界情况）。
           题面要自足：学生复习时已不记得资料里的例子，不要写「课件例子」「按课件」「如图」「图 3-34」「第 x 页」这类说法；用到的文法、代码、转换表、图中的结点和边等写进题面。
        5. 数学公式用 LaTeX 写在 $…$ 里；正文里的引号用中文引号“”。
        6. 只输出一个 JSON 对象，不要输出任何其他文字，也不要用代码块包裹。字段：
           - key_point：先写，一句话说明原题的关键判断点或方法，以及新题如何仍然考它、用的是哪种改编方式
           - stem：新题题面，分小问时用 1）2）编号，每小问一行
           - answer：参考答案，Markdown，写出关键步骤；最后用一句话说明这道题针对学生以往的什么问题（没有记录时说明换了什么角度）
           - parts：小问编号数组，与题面里的编号一致，如 ["1）", "2）"]；不分小问时省略
        7. 以往改编题被学生评价「出得好」的，可以参考它的改法；被标记「有问题」的，要避免同样的问题。
        """ + (hasImages ? """

        8. 新题不会显示任何图片（原题图是整道原题的截图，不能沿用）。题目要用到的图（如状态转换图、语法分析树、页表、目录结构）把内容用文字或 Markdown 表格写进题面：列出全部结点和边、表格的每一行数据，让学生不看图也能作答；不要写「如图」「见原题图」「图 x-x」。参考答案需要画图的，同样用表格或列出结点和边的方式写出。
        """ : "") + (q.isBlank ? """

        \(hasImages ? 9 : 8). 原题是填空题，新题也出成填空题：题面里每个空写成「____（1）」「____（2）」，parts 写 ["（1）", "（2）"]；只有一个空时也写 ["（1）"]。每空答案唯一、简短，answer 里逐空写出答案再给简要解析。
           另加字段 accept：与 parts 一一对应的数组，每项是这一空可接受的答案数组，第一项是标准答案，其余是等价写法（大小写、空格、同义说法等），如 [["PCB"], ["奇", "奇数"]]。
        """ : "")

        var user = "【原题】\n" + (q.stemForAI ?? "（题面见附图）") + "\n"
        user += "\n【原题参考答案】\n" + (q.answerForAI ?? "（答案见附图）") + "\n"
        user += Prompts.subjectiveExplanation(q, pack: pack)
        let tested = (q.tests.map { [$0] } ?? []) + (q.alsoTests ?? [])
        if !tested.isEmpty {
            user += "\n【本题考查的知识点】" + tested.map(pack.pointTitle).joined(separator: "、") + "\n"
        }
        let peers = peerQuestions(pack: pack, of: q)
        if !peers.isEmpty {
            user += "\n【同一知识点的其他原书题】（只作出题风格和难度参照，不要照抄）\n"
            for p in peers { user += "- " + String((p.stemForAI ?? "").prefix(800)) + "\n" }
        }
        let basis = (q.requires ?? []).compactMap { pack.chunks[$0] }
        if !basis.isEmpty {
            user += "\n【出题依据的资料原文】\n"
            for c in basis { user += "### \(c.title)\n\(c.text)\n" }
        }
        if let parts = q.parts, !parts.isEmpty {
            user += "\n【小问与得分点】\n"
            for p in parts {
                user += p.label + (p.points.map { " 得分点：" + $0.joined(separator: "；") } ?? "") + "\n"
            }
        }
        user += "\n【学生做这道题的记录】（按时间先后）\n"
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        let started = attempts.filter { $0.revealedAt != nil }
        if started.isEmpty { user += "（还没有看过参考答案的作答）\n" }
        for (i, a) in started.enumerated() {
            let mode = AttemptMode.label(of: a.mode)
            var line = "\(i + 1). \(df.string(from: a.revealedAt ?? a.createdAt))（\(mode)）"
            if let c = a.confidence.flatMap(SubjectiveConfidence.init(rawValue:)) { line += "看答案前：\(c.label)" }
            line += "，书写 \(Int(a.writingSeconds / 60)) 分钟"
            if a.isImmediateRedo { line += "（看过答案不久后重做）" }
            if let r = a.resultValue {
                let parts = zip(a.partLabels, a.parts).map { "\($0) \($1.label)" }.joined(separator: "，")
                line += "，自评：\(r.label)（\(parts)）"
            } else {
                line += "，还没有自评"
            }
            let causes = a.causeLines(pack.pointTitle)
            if !causes.isEmpty { line += "，错误类型与原因：\(causes.joined(separator: "；"))" }
            if let note = a.correctionNote, !note.isEmpty { line += "，学生的订正笔记：\(note)" }
            user += line + "\n"
            for g in a.gradings where !g.text.isEmpty {
                user += "   AI 批改（\(df.string(from: g.createdAt))\(g.completed ? "" : "，未完成")）：\n"
                user += String(GradingVerdict.displayText(g.text).prefix(2500))
                    .split(separator: "\n").map { "   " + $0 }.joined(separator: "\n") + "\n"
            }
        }
        user += variantHistory(variants, faults: faults, pack: pack, df: df)
        user += "\n请输出改编后的新题 JSON。"

        let images = !sendImages ? [] : ((q.questionImage.map { [$0] } ?? []) + (q.answerImages ?? []))
            .compactMap { HandwritingExport.jpeg(contentsOf: pack.root.appending(path: $0)) }
        return (system, [ChatTurn(role: .user, text: user, images: images)])
    }

    // MARK: - 提示词

    /// 以往改编题的结果，交给下一次改编参考。faults：评价过的改编题（按改编题 id）：标记有错的、评价出得好的
    private static func variantHistory(_ variants: [VariantAttempt], faults: [String: QuestionMark],
                                       pack: StudyPack, df: DateFormatter) -> String {
        guard !variants.isEmpty else { return "" }
        var text = "\n【以往改编题的结果】（按时间先后，避免重复出相同的题）\n"
        // 同一道改编题重做过几次时，全文只附一次
        var shown = Set<String>()
        for (i, v) in variants.enumerated() {
            text += "\(i + 1). \(df.string(from: v.createdAt))：\(String(v.stem.prefix(200)))"
            text += " —— \(v.resultValue?.label ?? v.result)"
            if v.partLabels.count > 1 {
                text += "（" + zip(v.partLabels, v.parts).map { "\($0) \($1.label)" }.joined(separator: "，") + "）"
            }
            let causes = v.causeLines(pack.pointTitle)
            if !causes.isEmpty { text += "，\(v.isCorrect ? "没把握的原因" : "错误类型与原因")：" + causes.joined(separator: "；") }
            if let note = v.correctionNote, !note.isEmpty { text += "，订正笔记：\(note)" }
            if let id = v.variantID, let mark = faults[id], !mark.faulty, mark.ratedGoodAt != nil {
                text += "。学生评价这道改编题出得好，可以参考它的改法（但不要出一样的题）"
                if shown.insert(id).inserted, let full = v.content.flatMap(QuestionSnapshot.init)?.markdown {
                    text += "\n   这道出得好的改编题全文：\n" + String(full.prefix(3000))
                        .split(separator: "\n", omittingEmptySubsequences: false).map { "   " + $0 }.joined(separator: "\n")
                }
            }
            if let id = v.variantID, let mark = faults[id], mark.faulty {
                text += "。学生标记这道改编题有错" + (mark.faultyDescription.map { "：\($0)" } ?? "") + "，结果不算数，请避免同样的问题"
                // 附上完整题目（选项、答案与解析），让 AI 能对照看出错在哪里
                if shown.insert(id).inserted, let full = v.content.flatMap(QuestionSnapshot.init)?.markdown {
                    text += "\n   这道有问题的改编题全文：\n" + String(full.prefix(3000))
                        .split(separator: "\n", omittingEmptySubsequences: false).map { "   " + $0 }.joined(separator: "\n")
                }
            }
            text += "\n"
        }
        return text
    }

    static func prompt(pack: StudyPack, question q: Question, attempts: [AttemptRecord],
                       variants: [VariantAttempt] = [], faults: [String: QuestionMark] = [:]) -> (String, [ChatTurn]) {
        let figures = (q.figures ?? []).compactMap { pack.figures[$0] }
        let system = """
        你是《\(pack.title)》的出题老师，正在为学生准备一道复习题。给你一道学生做过的原题、它的答案与解析、考查的知识点、同一知识点的其他原书题、出题依据的资料原文，以及学生以往做这道题的全部作答记录（选了什么、是否正确、把握程度、自评的错误类型和原因、订正笔记、当时 AI 讲评的对话）和以往改编题的结果。

        请在原题基础上改编出一道新题：
        1. 先找出原题的关键判断点：做对这道题必须想清楚的那一点（如“只有缺页且没有空闲页框时才需要页面置换”“文件打开后用文件描述符而不是文件名访问”），而不是笼统的知识点。新题必须仍然卡在这个判断点上，不能换去考同一知识点下的其他内容。学生以往选过某个错误选项或混淆过某两个概念时，新题要让这种误解再次露出来，检验是否真正纠正；学生每次都确定地答对时，换一个角度考这个判断点。
        2. 不能只是换选项顺序或同义改写，要让学生不能凭记住原题答案作答。改编方式（推荐前两种）：
           - 平级改编：换数据、换场景、换例子，考法和解题步骤与原题相同（如原题是某系统的需求漏写了一种情况的处理，新题换成另一个系统漏写了另一种情况）。这是最稳妥的做法，推荐。
           - 原题问“选哪个/哪些”（考记忆性结论，如哪种分配方式开销最大），新题给一个具体情形让学生用这条结论判断，或改问“为什么”：判断几条说明原因或机理的陈述。
           - 给一个具体的错误做法或错误结果，问错在哪里。
           - 改变问法（“正确的是”改为“错误的是”），改写或替换陈述，重新设计干扰项。
           要避免：
           - 不能变简单、变抽象：原题给的是具体情形（一段代码、一个输入串、一组数据），新题也要给具体情形，不能改成背一条抽象规则或定义。
           - 原题的核心材料（代码、文法、表达式、数据、例子）不能原样照搬：至少改动其中会影响结论的地方，让学生必须重新分析，而不是认出这段材料就想起原题结论。也不要直接搬用资料原文或原题解析里现成的例子。
           - 新题的正确答案不能只是照搬原文或原题解析中已经直接写出的某句结论或某个例子的结果。
           输出前自查：如果新题去掉选项顺序后与原题基本相同，就重新改编。
        3. 难度和篇幅与原题相当：
           - 题干长度、做题时间与原题接近；不要为了说清新情形补充大段规则说明，不增加推理或计算步骤。
           - 题干不能透露答案：不要在题干里写出正确选项的关键词或理由。
           - 干扰项要像原题的干扰项一样容易混淆：用原文里相近、容易弄混的概念或说法，不要编一眼就能排除的明显错误。可以沿用原题干扰项所代表的误解。
           - 【同一知识点的其他原书题】展示了这本书的出题风格和难度，新题要与它们相当。
           - 换了数据或情形后，检查条件是否完整：题干里的规则说清了没有，会不会有两种理解或多出边界情况，答案是否仍然唯一。
        4. 知识只能来自提供的资料原文和原题解析，不补充原文以外的知识，答案必须能从原文推出，且答案唯一（多选题的正确选项组合唯一）。
           题干要自足：学生复习时已不记得资料里的例子，不要写「课件例子」「按课件」「如图」「图 3-34」「第 x 页」这类说法；用到的文法、代码、转换表、图中的结点和边等写进题干。
        5. 题型与原题相同（\(q.type.rawValue)）。数学公式用 LaTeX 写在 $…$ 里；正文里的引号用中文引号“”。
           以往改编题被学生评价「出得好」的，可以参考它的改法；被标记「有问题」的，要避免同样的问题。
        6. 只输出一个 JSON 对象，不要输出任何其他文字，也不要用代码块包裹。字段：
           - key_point：先写，一句话说明原题的关键判断点，以及新题如何仍然卡在这一点上、用的是哪种改编方式
           - type：与原题相同
           - polarity：positive（选正确的、符合的）或 negative（选错误的、不属于的）
           - stem：题干，保留（ ）作为作答位置
           - single 题：options 为 {"A": "...", "B": "...", "C": "...", "D": "..."}，answer 为正确选项字母
           - multi 题（多选）：options 同 single，answer 为全部正确选项的字母按字母序连写，如 "ABD"；至少一个正确选项，不要每次都是全选
           - judge 题（判断）：不写 options，stem 是一句待判断的陈述（不要写「判断对错：」前缀），answer 为 "正确" 或 "错误"；polarity 写 positive
           - combo 题：statements 为 {"I": {"text": "...", "truth": true}, ...}（键用 I、II、III、IV），options 为 {"A": ["I","III"], ...}，answer 为正确选项字母；truth 为 true 的陈述集合必须恰好等于正确选项包含的陈述
           - multi_blank 题：shared_options 为 {"A": "...", ...}，blanks 为 [{"answer": "B", "cue": "这一空考的是什么"}, ...]，按题干中（ ）的顺序
           - explanation：解析，说明为什么选这个答案、其他选项错在哪里；如果是针对学生以往的错误设计的，最后用一句话点明这道题想检验的误解
           - hint：可选，一句提示
           - distractors：可选，single / multi 题中选了某个错误选项暴露出的知识点 id，只能从【本题考查的知识点】给出的 id 中选
        """ + (figures.isEmpty ? """

        7. 新题不会显示任何图片，题干不要写「如图」「图 x-x」；需要图时把内容用文字或 Markdown 表格写进题干。
        """ : """

           - figures：可选，新题要显示的原题附图 id 数组，只能从【原题附图】给出的 id 中选
        7. 原题附有图（见【原题附图】，图片依次附在消息里）。新题仍然基于同一张图（例如还是图中这个 NFA，只是换了所求的状态集合或输入符号）时，在 figures 里写上这张图的 id，App 会在题干下显示它，题干可以写「如图」或沿用原书的图号。新题改动了图的内容（换了表达式、结点或边、表格数据）时不要写 figures，也不要写「如图」「图 x-x」，而是把新图的全部内容用文字或 Markdown 表格写进题干（列出全部结点和边、每一行数据），让学生不看图也能作答。没写 figures 时新题不会显示任何图片。
        """)

        var user = "【原题】\(q.stem)\n"
        user += "（题型：\(q.type.rawValue)，\(q.polarity == .negative ? "选错误的/不符合的" : "选正确的/符合的")）\n"
        switch q.type {
        case .single, .multi:
            for k in q.optionKeys { user += "\(k). \(q.options?[k] ?? "")\n" }
        case .judge:
            break
        case .combo:
            for k in q.statementKeys {
                let st = q.statements?[k]
                user += "\(Roman.glyph(k)). \(st?.text ?? "")（\(st?.truth == true ? "正确" : "错误")）\n"
            }
            for k in q.optionKeys {
                user += "\(k). " + (q.comboOptions?[k] ?? []).map(Roman.glyph).joined(separator: "、") + "\n"
            }
        case .multiBlank:
            for k in q.optionKeys { user += "\(k). \(q.sharedOptions?[k] ?? "")\n" }
            for (i, b) in (q.blanks ?? []).enumerated() { user += "第 \(i + 1) 空：答案 \(b.answer)（\(b.cue)）\n" }
        }
        if let a = q.answer { user += "【正确答案】\(a)\n" }
        user += "【解析】\(q.explanation)\n"
        if !figures.isEmpty {
            user += "\n【原题附图】（图片按这个顺序附在消息里）\n"
            for f in figures { user += "id：\(f.id)，\(f.caption)\n图中内容：\n\(f.transcriptText)\n" }
        }

        let tested = q.testedPoints
        if !tested.isEmpty {
            user += "【本题考查的知识点】" + tested.map { "\($0)（\(pack.pointTitle($0))）" }.joined(separator: "、") + "\n"
        }
        let peers = peerQuestions(pack: pack, of: q)
        if !peers.isEmpty {
            user += "\n【同一知识点的其他原书题】（只作出题风格和难度参照，不要照抄）\n"
            for p in peers { user += peerText(p) }
        }
        let basis = q.requires.compactMap { pack.chunks[$0] }
        if !basis.isEmpty {
            user += "\n【出题依据的资料原文】\n"
            for c in basis { user += "### \(c.title)\n\(c.text)\n" }
        }

        user += "\n【学生做这道题的记录】（按时间先后）\n"
        if attempts.isEmpty { user += "（没有记录）\n" }
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        for (i, a) in attempts.enumerated() {
            let mode = a.mode == AttemptMode.redo.rawValue ? "错题重做" : AttemptMode.label(of: a.mode)
            var line = "\(i + 1). \(df.string(from: a.createdAt))（\(mode)）选 \(a.selection.replacingOccurrences(of: ",", with: "、"))，"
            line += a.isCorrect ? "正确" : "错误"
            line += "，把握程度：\(confidenceLabel(a.confidence))，用时 \(Int(a.durationSeconds)) 秒"
            if a.isImmediateRedo {
                line += "（看过答案 \(Int((a.sinceAnswerSeen ?? 0) / 60)) 分钟后重做）"
            }
            if a.selectionHistory.count > 1 {
                if a.selectionTimes.count == a.selectionHistory.count {
                    let steps = zip(a.selectionHistory, a.selectionTimes).map { "\($0)（第 \(Int($1)) 秒）" }
                    line += "，作答过程中改选：\(steps.joined(separator: " → "))"
                } else {
                    line += "，作答过程中改选：\(a.selectionHistory.joined(separator: " → "))"
                }
            }
            if a.hintShown { line += "，看过提示" }
            if !a.weakPoints.isEmpty { line += "，暴露的知识点：\(a.weakPoints.map(pack.pointTitle).joined(separator: "、"))" }
            let types = a.causeTypes.map(\.label).joined(separator: "、")
            if !types.isEmpty { line += a.isCorrect ? "，自评没把握的原因：\(types)" : "，自评错误类型：\(types)" }
            if !a.confusedPoints.isEmpty {
                line += "，认为弄混的知识点：\(a.confusedPoints.map(pack.pointTitle).joined(separator: "、"))"
            }
            if let note = a.errorNote, !note.isEmpty { line += "，学生写的错误原因：\(note)" }
            if let note = a.correctionNote, !note.isEmpty { line += "，学生的订正笔记：\(note)" }
            user += line + "\n"
            if let data = a.reviewConversationData,
               let saved = try? JSONDecoder().decode(SavedConversation.self, from: data) {
                let talk = saved.messages.map { "\($0.role == "user" ? "学生" : "AI")：\($0.text)" }
                    .joined(separator: "\n")
                if !talk.isEmpty {
                    user += "   当时的 AI 讲评和学生的提问：\n" + String(talk.prefix(2500))
                        .split(separator: "\n").map { "   " + $0 }.joined(separator: "\n") + "\n"
                }
            }
        }
        user += variantHistory(variants, faults: faults, pack: pack, df: df)
        user += "\n请输出改编后的新题 JSON。"
        let images = figures.compactMap { HandwritingExport.jpeg(contentsOf: pack.root.appending(path: $0.image)) }
        return (system, [ChatTurn(role: .user, text: user, images: images)])
    }

    // MARK: - 解析与检查

    /// id：恢复存下的改编题时沿用原来的 id；nil 时新起一个
    static func parse(_ text: String, original q: Question, id: String? = nil) throws -> (Question, String) {
        guard text.contains("{") else { throw VariantError.noJSON }
        guard let (json, parsed) = jsonObject(in: text) else { throw VariantError.invalid("JSON 无法解析") }
        var obj = parsed
        // 包里的字段由原题补上：知识点、依据的知识块、页码
        obj["id"] = id ?? newID(originalID: q.id)
        obj["num"] = q.num
        obj["type"] = q.type.rawValue
        // 多选题答案可能写成 "A、B, D" 或数组，统一成按字母序连写
        if q.type == .multi {
            let raw = (obj["answer"] as? [String])?.joined() ?? (obj["answer"] as? String) ?? ""
            obj["answer"] = Set(raw.uppercased().filter { $0.isLetter && $0.isASCII }.map(String.init)).sorted().joined()
        }
        obj["ai_authored"] = true
        obj["page"] = q.page
        obj["explanation_page"] = q.explanationPage
        obj["requires"] = q.requires
        if let t = q.tests { obj["tests"] = t }
        if let a = q.alsoTests { obj["also_tests"] = a }
        let allowed = Set(q.testedPoints)
        if let d = obj["distractors"] as? [String: [String]] {
            obj["distractors"] = d.mapValues { $0.filter(allowed.contains) }.filter { !$0.value.isEmpty }
        } else {
            obj.removeValue(forKey: "distractors")
        }
        // 只能引用原题的附图
        let allowedFigures = Set(q.figures ?? [])
        let figures = ((obj["figures"] as? [Any]) ?? []).compactMap { $0 as? String }.filter(allowedFigures.contains)
        if figures.isEmpty { obj.removeValue(forKey: "figures") } else { obj["figures"] = figures }
        let data = try JSONSerialization.data(withJSONObject: obj)
        let v: Question
        do {
            v = try JSONDecoder().decode(Question.self, from: data)
        } catch {
            throw VariantError.invalid(String(describing: error))
        }
        try check(v)
        return (escapeMarkdown(v, obj: obj), json)
    }

    /// 选项、陈述、解析按 Markdown 显示，公式外的 * 会被当成斜体标记，转义后重新解码
    private static func escapeMarkdown(_ v: Question, obj: [String: Any]) -> Question {
        func esc(_ s: String) -> String {
            var out = "", inMath = false
            for ch in s {
                if ch == "$" { inMath.toggle() }
                if ch == "*" && !inMath && !out.hasSuffix("\\") { out += "\\*" } else { out.append(ch) }
            }
            return out
        }
        var o = obj
        for key in ["explanation", "hint"] { if let s = o[key] as? String { o[key] = esc(s) } }
        if v.type != .combo, let opts = o["options"] as? [String: String] { o["options"] = opts.mapValues(esc) }
        if let opts = o["shared_options"] as? [String: String] { o["shared_options"] = opts.mapValues(esc) }
        if var st = o["statements"] as? [String: [String: Any]] {
            for (k, var item) in st { if let t = item["text"] as? String { item["text"] = esc(t) }; st[k] = item }
            o["statements"] = st
        }
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let q = try? JSONDecoder().decode(Question.self, from: data) else { return v }
        return q
    }

    private static func check(_ v: Question) throws {
        guard !v.stem.isEmpty, !v.explanation.isEmpty else { throw VariantError.invalid("缺少题干或解析") }
        switch v.type {
        case .single:
            guard let opts = v.options, opts.count >= 2, let a = v.answer, opts[a] != nil else {
                throw VariantError.invalid("答案不在选项中")
            }
        case .combo:
            guard let opts = v.comboOptions, let st = v.statements, let a = v.answer, let picked = opts[a] else {
                throw VariantError.invalid("组合题缺少陈述或答案")
            }
            let truths = Set(st.filter(\.value.truth).map(\.key))
            guard truths == Set(picked), opts.values.allSatisfy({ $0.allSatisfy { st[$0] != nil } }) else {
                throw VariantError.invalid("正确陈述与答案选项不一致")
            }
        case .multiBlank:
            guard let opts = v.sharedOptions, let blanks = v.blanks, !blanks.isEmpty,
                  blanks.allSatisfy({ opts[$0.answer] != nil }) else {
                throw VariantError.invalid("填空答案不在选项中")
            }
        case .multi:
            guard let opts = v.options, opts.count >= 2, !v.answerSet.isEmpty,
                  v.answerSet.allSatisfy({ opts[$0] != nil }), v.answer == v.answerSet.sorted().joined() else {
                throw VariantError.invalid("多选题答案不是按字母序写的选项字母")
            }
        case .judge:
            guard let a = v.answer, Question.judgeKeys.contains(a) else {
                throw VariantError.invalid("判断题答案不是「正确」或「错误」")
            }
        }
    }
}
