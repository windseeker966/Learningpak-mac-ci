import Foundation
import SwiftData

/// 回答里指向书中某处的引用：节号#轮次（第几轮从 1 起）或题号
enum BookRef {
    case round(SectionFile, index: Int)
    case question(SectionFile, roundIndex: Int, questionIndex: Int, id: String)

    var section: SectionFile {
        switch self {
        case .round(let s, _), .question(let s, _, _, _): s
        }
    }

    var roundIndex: Int {
        switch self {
        case .round(_, let i), .question(_, let i, _, _): i
        }
    }

    var start: StudyPosition {
        switch self {
        case .round(_, let i): StudyPosition(roundIndex: i, page: .lecture)
        case .question(_, let r, let q, _): StudyPosition(roundIndex: r, page: .question(q))
        }
    }

    /// 解析「3.1#2」「3.1 第2轮」「3.1」或题号「3.1-Q19」
    static func resolve(_ raw: String, in pack: StudyPack) -> BookRef? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let loc = pack.questionLocation(r) {
            return .question(loc.section, roundIndex: loc.roundIndex, questionIndex: loc.questionIndex, id: r)
        }
        if let m = r.wholeMatch(of: /(.+?)\s*(?:#|＃|第)\s*(\d+)\s*轮?/), let s = pack.section(String(m.1).trimmingCharacters(in: .whitespaces)),
           let n = Int(m.2), (1...s.rounds.count).contains(n) {
            return .round(s, index: n - 1)
        }
        if let s = pack.section(r), !s.rounds.isEmpty { return .round(s, index: 0) }
        return nil
    }
}

/// 回答中的查阅、跳转标记
enum BookChatMarker {
    case lookup(String)
    case jump(String)

    private static let pattern = /\[\[\s*(查阅|跳转)[\s:：]*([^\]]+?)\s*\]\]/

    /// 一行里的标记，以及去掉标记后剩下的文字
    static func split(line: String) -> (markers: [BookChatMarker], rest: String) {
        var markers: [BookChatMarker] = []
        for m in line.matches(of: pattern) {
            let target = String(m.2)
            markers.append(m.1 == "查阅" ? .lookup(target) : .jump(target))
        }
        guard !markers.isEmpty else { return ([], line) }
        return (markers, line.replacing(pattern, with: "").trimmingCharacters(in: .whitespaces))
    }

    /// 回答里要查阅的目标（按出现顺序，去重）
    static func lookups(in text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            for case .lookup(let t) in split(line: line).markers where !out.contains(t) { out.append(t) }
        }
        return out
    }
}

/// 学生在这本书上的学习情况，每次请求前从数据库重新读取
struct BookChatProgress {
    let attempts: [AttemptRecord]
    let subjective: [SubjectiveAttempt]
    let progresses: [String: SectionProgress]
    let done: Set<String>
    let dueReviews: [String]

    /// 都是这本书的记录；查询见 BookChatProgress.load
    @MainActor
    init(pack: StudyPack, attempts: [AttemptRecord], subjective: [SubjectiveAttempt],
         summaries: [PassageSummaryAttempt], translations: [BackTranslationAttempt],
         progresses: [SectionProgress], reviews: [ReviewItem]) {
        self.attempts = attempts.filter { !(AttemptMode(rawValue: $0.mode)?.isAI ?? false) }
            .sorted { $0.createdAt < $1.createdAt }
        self.subjective = subjective.sorted { $0.createdAt < $1.createdAt }
        self.progresses = Dictionary(progresses.map { ($0.sectionID, $0) }, uniquingKeysWith: { a, _ in a })
        self.done = SectionCompletion.doneQuestions(pack: pack, attempts: attempts, subjective: subjective,
                                                    summaries: summaries, translations: translations)
        self.dueReviews = reviews.filter { ReviewScheduler.isDue($0) && pack.isReviewable($0.questionID) }
            .sorted { $0.dueAt < $1.dueAt }.map(\.questionID)
    }

    /// 最近一次作答的结果：✓ 对、✗ 错、◐ 部分对、👀 看过答案还没自评；没做过为 nil
    func mark(_ qid: String) -> String? {
        let choice = attempts.last { $0.questionID == qid }
        let sub = subjective.last { $0.questionID == qid && ($0.assessedAt != nil || $0.revealedAt != nil) }
        if let choice, choice.createdAt > sub?.createdAt ?? .distantPast {
            return choice.isCorrect ? "✓" : "✗"
        }
        guard let sub else { return nil }
        switch sub.resultValue {
        case .correct: return "✓"
        case .partial: return "◐"
        case .wrong, .blank: return "✗"
        default: return "👀"
        }
    }

    /// 答错时标出的薄弱知识点，按次数排列
    func weakPoints(limit: Int) -> [(id: String, count: Int)] {
        var counts: [String: Int] = [:]
        for a in attempts where !a.isCorrect { for p in a.weakPoints { counts[p, default: 0] += 1 } }
        for a in subjective where a.resultValue.map({ $0 != .correct }) == true {
            for p in a.weakPoints { counts[p, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map { ($0.key, $0.value) }
    }
}

/// 全书「AI 提问」：系统提示里只放全书目录和学生的进度；AI 需要原文时写 [[查阅 节号#轮次]]，
/// App 取出那几轮的原文、题目和作答记录自动发给它，它再接着回答。回答里的 [[跳转 …]] 显示为跳到那一轮或那道题的按钮。
enum BookChatPrompts {
    /// 一次查阅最多取几轮
    static let maxLookupRounds = 4
    /// 一次提问最多自动查阅几次
    static let maxLookups = 3

    static func system(pack: StudyPack, progress: BookChatProgress) -> String {
        let label = pack.sourceLabel
        return """
        你是《\(pack.title)》的学习助手。学生正在按这本资料（称作「\(label)」）逐节学习，现在在这本书的「AI 提问」里向你提问。

        你手里有下面的【全书目录与进度】：每一节分成若干轮，每轮先讲几个知识块，再做几道题；目录里列出了每轮讲的知识块标题、题号和题干开头，以及学生的作答情况。目录里没有原文和题目全文。

        规则：
        1. 需要\(label)原文、题目全文、答案解析或学生的具体作答时，用查阅命令：单独占一行写 [[查阅 节号#第几轮]]，如 [[查阅 3.1#2]]；也可以写题号，如 [[查阅 3.1-Q19]]（取这道题所在的那一轮）。一次最多 \(maxLookupRounds) 行。写了查阅命令就停下，不要再写别的内容；App 会把那几轮的原文、题目（含答案、解析）和学生的作答记录发给你，你再接着回答。学生看不到你取到的资料，回答时不要说「你发来的资料」。
        2. 回答书中具体内容、题目、解析的问题之前，先查阅相关的轮次，依据\(label)原文回答，不要凭印象替\(label)说话。\(label)没有讲到的，先明确说「\(label)没有涉及」，再给简短的一般性说明。
        3. 只问学习进度、学习安排、某个内容在哪一节哪一轮这类问题时，看目录就够，不用查阅。
        4. 提到值得回去看的地方时，单独占一行写跳转按钮：[[跳转 节号#第几轮]] 打开那一轮的讲解，[[跳转 题号]]（如 [[跳转 3.1-Q19]]）打开那道题。App 会把这一行显示成按钮。只用目录里存在的节号、轮次和题号，按钮前后用一句话说明为什么要去看。
        5. 用中文回答，使用 Markdown；公式用 LaTeX，行内写在 $…$ 里，单独成行的写成独立一段的 $$…$$。需要写代码时用代码块。查阅到的原文附有图时，可以单独占一行写 [[图 图的id]] 显示原图。
        6. 学生可能划选你前面回答里的一段话提问，消息里会写明引文和所在段落。先核对那段是否准确，有不准确的地方要明确指出并更正。

        【全书目录与进度】
        \(catalog(pack: pack, progress: progress))
        """
    }

    /// 目录：章、节、轮，每轮的知识块标题和题目，以及进度
    static func catalog(pack: StudyPack, progress: BookChatProgress) -> String {
        var lines = ["作答标记：✓ 最近一次做对，✗ 最近一次做错，◐ 部分对，👀 看过答案还没自评，没有标记的是还没做过。"]
        let recent = progress.progresses.values.max { $0.updatedAt < $1.updatedAt }
        if let recent, let s = pack.section(recent.sectionID), !s.rounds.isEmpty {
            let i = min(recent.roundIndex, s.rounds.count - 1)
            let where_ = recent.phase == "lecture" ? "讲解" : "做题第 \(recent.questionIndex + 1) 题"
            lines.append("最近在学：\(s.section.id) \(s.section.title) 第 \(i + 1) 轮\(where_)（\(relative(recent.updatedAt))）")
        }
        var chapter = ""
        for s in pack.sections {
            if s.section.chapter != chapter {
                chapter = s.section.chapter
                lines.append("\n## \(chapter)")
            }
            let p = progress.progresses[s.section.id]
            let finished = SectionCompletion.completedRounds(s, p, progress.done, in: pack)
            let state = finished == s.rounds.count && !s.rounds.isEmpty ? "已学完"
                : p == nil ? "未开始" : "已完成 \(finished)/\(s.rounds.count) 轮，学到第 \(min(p!.roundIndex, max(s.rounds.count - 1, 0)) + 1) 轮"
            let pages = s.section.pages.map { "第 \(pageText($0)) 页；" } ?? "习题节，只有题；"
            lines.append("### \(s.section.id) \(s.section.title)（\(pages)\(state)）")
            for (i, r) in s.rounds.enumerated() {
                let topics = r.isExercise ? "不讲解，只做题"
                    : r.chunks.isEmpty
                    ? "回顾：\(r.recap?.topic ?? "")"
                    : r.chunks.compactMap { pack.chunks[$0] }.map { $0.isSupplement ? "\($0.title)（书外补充）" : $0.title }
                        .joined(separator: "；")
                let title = r.title.map { "「\($0)」" } ?? ""
                let questions = r.questions.map { qid in
                    "\(qid)\(progress.mark(qid) ?? "")「\(stemHead(qid, pack))」"
                }.joined(separator: " ")
                lines.append("- 第 \(i + 1) 轮\(title)｜讲：\(topics)" + (questions.isEmpty ? "" : "｜题：\(questions)"))
            }
        }
        let weak = progress.weakPoints(limit: 12)
        if !weak.isEmpty {
            lines.append("\n## 答错时暴露最多的知识点")
            lines.append(weak.map { "\(pack.pointTitle($0.id))（\($0.count) 次）" }.joined(separator: "；"))
        }
        if !progress.dueReviews.isEmpty {
            let shown = progress.dueReviews.prefix(30).joined(separator: " ")
            lines.append("\n## 复习队列\n今天到期 \(progress.dueReviews.count) 道：\(shown)\(progress.dueReviews.count > 30 ? " …" : "")")
        }
        return lines.joined(separator: "\n")
    }

    /// 题干开头：去掉代码块、合并空白，取前 30 个字
    private static func stemHead(_ qid: String, _ pack: StudyPack) -> String {
        let raw = pack.questions[qid]?.stem ?? pack.subjective[qid].map { $0.stem ?? "（题面是图片）" }
            ?? ReadingPracticeItem(id: qid, in: pack)?.label ?? ""
        let noCode = raw.replacing(/```[\s\S]*?```/, with: " ")
        let flat = noCode.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 30 ? String(flat.prefix(30)) + "…" : flat
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: date, relativeTo: .now)
    }

    // MARK: - 查阅

    /// 按回答里的查阅命令取出资料；没有查阅命令时为 nil
    static func lookupReply(for answer: String, pack: StudyPack, progress: BookChatProgress, used: Int)
        -> (text: String, shown: String)? {
        let targets = BookChatMarker.lookups(in: answer)
        guard !targets.isEmpty else { return nil }
        if used >= maxLookups {
            guard used == maxLookups else { return nil }
            return ("这次提问已经查阅了 \(maxLookups) 次，不能再查阅了。请根据已经取到的资料直接回答。",
                    "查阅次数已到上限，请 AI 直接回答")
        }
        var rounds: [(SectionFile, Int)] = []
        var missing: [String] = []
        for t in targets {
            guard let ref = BookRef.resolve(t, in: pack) else { missing.append(t); continue }
            if !rounds.contains(where: { $0.0.section.id == ref.section.section.id && $0.1 == ref.roundIndex }) {
                rounds.append((ref.section, ref.roundIndex))
            }
        }
        let taken = Array(rounds.prefix(maxLookupRounds))
        var text = "【查阅结果】以下是你要查阅的内容（学生看不到这条消息）。请依据这些资料接着回答学生的问题；还需要别的轮次可以再查阅。\n"
        if !missing.isEmpty { text += "\n找不到：\(missing.joined(separator: "、"))（请对照目录里的节号、轮次和题号）\n" }
        if rounds.count > taken.count { text += "\n一次最多查阅 \(maxLookupRounds) 轮，只取了前 \(maxLookupRounds) 轮。\n" }
        for (s, i) in taken { text += "\n" + roundMaterial(s, i, pack: pack, progress: progress) }
        let names = taken.map { "\($0.0.section.id) 第 \($0.1 + 1) 轮" }
        let shown = names.isEmpty ? "没有找到要查阅的内容" : "已把 \(names.joined(separator: "、")) 的原文和题目发给 AI"
        return (text, shown)
    }

    private static func roundMaterial(_ s: SectionFile, _ i: Int, pack: StudyPack, progress: BookChatProgress) -> String {
        let r = s.rounds[i]
        var out = "## \(s.section.id) \(s.section.title) · 第 \(i + 1) 轮"
        if let title = r.title { out += " · \(title)" }
        out += "\n"
        let chunks = (r.chunks.isEmpty ? r.recap?.from ?? [] : r.chunks).compactMap { pack.chunks[$0] }
        if r.chunks.isEmpty, let recap = r.recap {
            out += "（巩固回顾：\(recap.topic)。下面是回顾的知识块，它们在前面的轮次讲过）\n"
        }
        if !chunks.isEmpty {
            out += "\n【本轮讲的知识块】\n\n" + chunks.map { Prompts.chunkBlock($0, pack) }.joined(separator: "\n\n") + "\n"
        }
        let questions = r.questions
        if !questions.isEmpty {
            out += "\n【本轮题目】\n"
            for qid in questions {
                out += "\n" + questionMaterial(qid, pack: pack, progress: progress)
            }
        }
        return out
    }

    private static func questionMaterial(_ qid: String, pack: StudyPack, progress: BookChatProgress) -> String {
        if let q = pack.questions[qid] { return choiceMaterial(q, pack: pack, progress: progress) }
        if let q = pack.subjective[qid] { return subjectiveMaterial(q, pack: pack, progress: progress) }
        if let item = ReadingPracticeItem(id: qid, in: pack) { return "### \(qid)（\(item.label)）\n" }
        return "### \(qid)\n（题目不在包里）\n"
    }

    private static func choiceMaterial(_ q: Question, pack: StudyPack, progress: BookChatProgress) -> String {
        let kind = switch q.type {
        case .single: "单选题"
        case .multi: "多选题"
        case .judge: "判断题"
        case .combo: "组合选择题"
        case .multiBlank: "多空选择题"
        }
        var s = "### \(q.id)（第 \(q.num) 题，\(kind)\(q.aiAuthored ? "，AI 出题" : "")）\n\(q.stem)\n"
        switch q.type {
        case .single, .multi:
            for k in q.optionKeys { s += "\(k). \(q.options?[k] ?? "")\n" }
        case .judge:
            break
        case .combo:
            for k in q.statementKeys { s += "\(Roman.glyph(k)). \(q.statements?[k]?.text ?? "")\n" }
            for k in q.optionKeys { s += "\(k). " + (q.comboOptions?[k] ?? []).map(Roman.glyph).joined(separator: "、") + "\n" }
        case .multiBlank:
            for k in q.optionKeys { s += "\(k). \(q.sharedOptions?[k] ?? "")\n" }
        }
        s += "答案：\(q.answerText)" + (q.aiWritten == .answer ? "（\(pack.sourceLabel)没有答案，由 AI 补写）" : "") + "\n"
        s += "解析：\(q.explanation)\n"
        let records = progress.attempts.filter { $0.questionID == q.id }.suffix(5)
        if records.isEmpty {
            s += "学生作答：还没做过\n"
        } else {
            s += "学生作答（按时间）：\n"
            for a in records {
                var line = "- \(date(a.createdAt)) \(modeLabel(a.mode))：选 \(a.selection.replacingOccurrences(of: ",", with: "、"))，"
                line += (a.isCorrect ? "对" : "错") + "，把握：\(confidenceLabel(a.confidence))"
                let causes = a.causeTypes.map(\.label)
                if !causes.isEmpty { line += "，错因：\(causes.joined(separator: "、"))" }
                if let n = a.errorNote, !n.isEmpty { line += "（\(n)）" }
                if let n = a.correctionNote, !n.isEmpty { line += "；订正笔记：\(n)" }
                s += line + "\n"
            }
        }
        return s
    }

    private static func subjectiveMaterial(_ q: SubjectiveQuestion, pack: StudyPack, progress: BookChatProgress) -> String {
        var s = "### \(q.id)（第 \(q.num) 题，\(q.kindLabel)\(q.aiAuthored == true ? "，AI 出题" : "")）\n"
        s += (q.stem ?? "（题面是\(pack.sourceLabel)的图片，没有文字）") + "\n"
        if let a = q.answer {
            s += "参考答案" + (q.aiWritten == .answer ? "（\(pack.sourceLabel)没有答案，由 AI 补写）" : "") + "：\n\(a)\n"
        } else if q.answerImages?.isEmpty == false {
            s += "参考答案：（\(pack.sourceLabel)的答案是图片，没有文字）\n"
        }
        if let e = q.explanation {
            s += "解析" + (q.aiWritten != nil ? "（由 AI 编写）" : "") + "：\n\(e)\n"
        }
        let parts = q.parts ?? []
        for p in parts {
            if let a = p.shownAnswer { s += "\(p.label) \(a)\n" }
            if let pts = p.points, !pts.isEmpty { s += "\(p.label) 得分点：\(pts.joined(separator: "；"))\n" }
        }
        let records = progress.subjective.filter { $0.questionID == q.id && ($0.revealedAt != nil || $0.assessedAt != nil) }.suffix(5)
        if records.isEmpty {
            s += "学生作答：还没做过\n"
        } else {
            s += "学生作答（按时间）：\n"
            for a in records {
                var line = "- \(date(a.createdAt)) \(modeLabel(a.mode))：自评 \(a.resultValue?.label ?? "还没自评")"
                let partText = zip(a.partLabels, a.partResults).compactMap { label, raw in
                    PartResult(rawValue: raw).map { "\(label)\($0.label)" }
                }
                if partText.count > 1 { line += "（\(partText.joined(separator: "，"))）" }
                let causes = a.errorTypes.compactMap { ErrorType(rawValue: $0)?.label }
                if !causes.isEmpty { line += "，错因：\(causes.joined(separator: "、"))" }
                if let n = a.errorNote, !n.isEmpty { line += "（\(n)）" }
                if let n = a.correctionNote, !n.isEmpty { line += "；订正笔记：\(n)" }
                s += line + "\n"
            }
        }
        return s
    }

    private static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "review": "复习"
        case "redo": "重做"
        default: "学习"
        }
    }

    private static func date(_ d: Date) -> String {
        d.formatted(.dateTime.month().day().hour().minute())
    }
}
