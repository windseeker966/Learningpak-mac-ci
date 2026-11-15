import Foundation

// 教辅包（study-pack，schema_version 1）的数据结构，与 os-2027/FORMAT.md 一一对应。

nonisolated struct BookFile: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        let id: String
        let title: String
        let subject: String?
        /// 资料来源的称呼（如「课件」），界面显示为「<称呼>第 x 页」；默认「原书」
        let sourceLabel: String?
        /// false：本书的题不出 AI 改编题（AI 改编复习跳过，题目卡片不显示「AI改编」）；不写为可以改编
        let aiVariant: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, subject
            case sourceLabel = "source_label"
            case aiVariant = "ai_variant"
        }
    }

    struct SectionEntry: Decodable, Sendable {
        let id: String
        let file: String
    }

    let format: String
    let schemaVersion: Int
    let book: Meta
    /// 知识点库文件（相对包根目录），可选
    let knowledgePoints: String?
    let sections: [SectionEntry]

    enum CodingKeys: String, CodingKey {
        case format, book, sections
        case schemaVersion = "schema_version"
        case knowledgePoints = "knowledge_points"
    }
}

nonisolated struct KnowledgePointFile: Decodable, Sendable {
    let knowledgePoints: [KnowledgePoint]

    enum CodingKeys: String, CodingKey {
        case knowledgePoints = "knowledge_points"
    }
}

/// 全书共用的知识点：题目考查的对象，用来统计掌握度
nonisolated struct KnowledgePoint: Decodable, Sendable, Identifiable {
    let id: String
    let introducedIn: String
    let title: String
    /// 讲授它的知识块
    let taughtIn: [String]
    /// 对应的原书考点追踪
    let examTopics: [String]?
    let deprecated: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, deprecated
        case introducedIn = "introduced_in"
        case taughtIn = "taught_in"
        case examTopics = "exam_topics"
    }
}

nonisolated struct SectionFile: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        let id: String
        let title: String
        let chapter: String
        /// 书内页码；习题节没有
        let pages: [Int]?
        /// 原书 PDF，相对包根目录；「原文」页显示其中的页面。习题节没有
        let sourcePDF: String?
        /// PDF 第 1 页对应的书内页码，不写为 1
        let pdfFirstPage: Int?
        let scope: String
        /// exercises：习题节，只有取自书外（课程作业等）的题，没有知识块和原书 PDF；不写为普通的节
        let kind: String?
        /// false：本节的题不进复习（学习页照常做，作答照常记录）；不写为进复习
        let review: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, chapter, pages, scope, kind, review
            case sourcePDF = "source_pdf"
            case pdfFirstPage = "pdf_first_page"
        }

        var isExercises: Bool { kind == "exercises" }
    }

    let section: Meta
    /// 知识块；习题节没有
    let chunks: [Chunk]
    let figures: [Figure]?
    let questions: [Question]
    /// 已录入题面和答案的主观题，和选择题一样安排在 rounds 里；deferred 中的题尚不在此列
    let subjective: [SubjectiveQuestion]?
    /// 说法卡（考研政治这类要背的固定说法）
    let phrases: [Phrase]?
    let rounds: [Round]

    enum CodingKeys: String, CodingKey {
        case section, chunks, figures, questions, subjective, phrases, rounds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        section = try c.decode(Meta.self, forKey: .section)
        chunks = try c.decodeIfPresent([Chunk].self, forKey: .chunks) ?? []
        figures = try c.decodeIfPresent([Figure].self, forKey: .figures)
        questions = try c.decode([Question].self, forKey: .questions)
        subjective = try c.decodeIfPresent([SubjectiveQuestion].self, forKey: .subjective)
        phrases = try c.decodeIfPresent([Phrase].self, forKey: .phrases)
        rounds = try c.decode([Round].self, forKey: .rounds)
    }
}

/// 原书题目中由 AI 补写的部分，显示为题号旁的固定标签
nonisolated enum AIWritten: String, Decodable, Sendable {
    /// 原书有题无答案，答案与解析都由 AI 补写
    case answer
    /// 答案来自原书或试卷，只有解析由 AI 编写
    case explanation

    var label: String { self == .answer ? "AI解答" : "AI解析" }
}

nonisolated struct SubjectiveQuestion: Decodable, Sendable, Identifiable {
    let id: String
    let num: Int
    /// 题目所在页；习题节里取自课程作业等没有页码的题不写
    let page: [Int]?
    let answerPage: [Int]?
    let stem: String?
    let questionImage: String?
    let answer: String?
    let answerImages: [String]?
    /// 题面图、答案图的逐字转写：只给 AI 用，界面不显示
    var questionTranscript: String? = nil
    var answerTranscript: String? = nil
    /// 解题过程，显示在答案下面；原书只有答案时由 AI 编写（aiWritten 为 explanation）
    var explanation: String? = nil
    /// 出题前必须讲过的知识块
    let requires: [String]?
    /// 资料中没有这道题，由 AI 出题；答案也是 AI 编写
    let aiAuthored: Bool?
    /// 原书题目由 AI 补写的部分：answer 参考答案由 AI 补写；explanation 答案来自原书，只有解析由 AI 编写
    let aiWritten: AIWritten?
    /// 主考 / 兼考知识点；小问没有单独标注时用它
    let tests: String?
    let alsoTests: [String]?
    /// 小问：按小问自评、计入知识点掌握度；不写时整题算一问
    let parts: [Part]?
    let deprecated: Bool?
    /// blank：填空题，每空一个小问；不写为综合应用题
    let format: String?
    /// 填空题的作答方式：text 键盘输入、与 accept 比对；ink（默认）手写
    let input: String?
    /// 题目取自本节资料以外的另一本书时写书名（如「1000题第1章」）：页码、题号都是那本书的
    var source: String? = nil

    struct Part: Decodable, Sendable {
        /// 小问编号，与题面一致，如「1）」
        let label: String
        /// 这一问的参考答案（选填，整题答案里已有时可不写）
        let answer: String?
        let tests: String?
        let alsoTests: [String]?
        /// 得分点：这一问答对需要写出的关键步骤或结论
        let points: [String]?
        /// 键盘输入的填空题：可接受的答案，第一项是标准答案
        var accept: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case label, answer, tests, points, accept
            case alsoTests = "also_tests"
        }

        /// 填空题这一空显示的答案
        var shownAnswer: String? { answer ?? accept?.first }
    }

    enum CodingKeys: String, CodingKey {
        case id, num, page, stem, answer, explanation, deprecated, requires, tests, parts, format, input, source
        case alsoTests = "also_tests"
        case aiAuthored = "ai_authored"
        case aiWritten = "ai_written"
        case answerPage = "answer_page"
        case questionImage = "question_image"
        case answerImages = "answer_images"
        case questionTranscript = "question_transcript"
        case answerTranscript = "answer_transcript"
    }

    /// 给 AI 的题面文字：文字题面，没有时用题面图的转写
    var stemForAI: String? { stem ?? questionTranscript }
    /// 给 AI 的答案文字：文字答案加上答案图的转写
    var answerForAI: String? {
        let texts = [answer, answerTranscript].compactMap { $0 }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
    /// 有图的地方都有转写：AI 改编可以只发文字
    var transcribed: Bool {
        (questionImage == nil || questionTranscript != nil) && ((answerImages ?? []).isEmpty || answerTranscript != nil)
    }

    /// 自评和统计用的小问；没有标注小问时整题算一问
    var effectiveParts: [Part] {
        if let parts, !parts.isEmpty { return parts }
        return [Part(label: "全题", answer: nil, tests: tests, alsoTests: alsoTests, points: nil)]
    }

    /// 某一问考查的知识点，主考在前；小问没写时用整题的
    func testedPoints(of part: Part) -> [String] {
        let main = part.tests ?? tests
        let also = part.tests == nil ? (alsoTests ?? []) : (part.alsoTests ?? [])
        return (main.map { [$0] } ?? []) + also
    }

    var testedPoints: [String] { (tests.map { [$0] } ?? []) + (alsoTests ?? []) }

    /// 填空题
    var isBlank: Bool { format == "blank" }
    /// 键盘输入的填空题：提交时自动比对，对不上的交给 AI 和自评
    var typed: Bool { isBlank && input == "text" }
    /// 题型名：填空题 / 综合题
    var kindLabel: String { isBlank ? "填空题" : "综合题" }
    /// 自评可选的结果：填空题只看对错，没有「部分对」
    var assessmentOptions: [PartResult] { isBlank ? [.correct, .wrong, .blank] : [.correct, .partial, .wrong, .blank] }
}

nonisolated struct Chunk: Decodable, Sendable, Identifiable {
    struct ExamPoint: Decodable, Sendable {
        let topic: String
        let years: [Int]
    }

    let id: String
    let title: String
    let path: [String]
    let page: [Int]
    let text: String
    let examPoints: [ExamPoint]?
    let figures: [String]?
    let deprecated: Bool?
    /// passage：阅读理解的文章，做题时显示在题目上方，不做 AI 讲解；不写为普通知识块
    let kind: String?
    /// 文章的回译句：看中文写英文，再和原句对照
    let backTranslation: [BackTranslationDrill]?
    /// 文章的参考概括：每段一句，加全文概括
    let summary: PassageSummaryReference?

    /// 书外补充：不是原书内容，用户同意后由 AI 编写；page 是它延伸的原书页码
    let supplement: Supplement?

    struct Supplement: Decodable, Sendable {
        /// 用户同意加入的日期
        let approved: String
        let reason: String
    }

    enum CodingKeys: String, CodingKey {
        case id, title, path, page, text, figures, deprecated, kind, summary, supplement
        case examPoints = "exam_points"
        case backTranslation = "back_translation"
    }

    var isPassage: Bool { kind == "passage" }
    var isSupplement: Bool { supplement != nil }

    /// 位置说明：原书页码；书外补充写明不是原书内容
    func location(sourceLabel: String) -> String {
        isSupplement ? "书外补充 · 非\(sourceLabel)内容（延伸第 \(pageText(page)) 页）" : "第 \(pageText(page)) 页"
    }

    /// 文章的段落：按空行分段，段内的换行只是录入时的折行，换成空格。
    /// 生词在文中的位置按这里的文字记录
    var paragraphs: [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ") }
            .filter { !$0.isEmpty }
    }
}

/// 回译句：文章中的一句原文及其中文译文
nonisolated struct BackTranslationDrill: Decodable, Sendable, Hashable {
    /// 第几段，从 1 起
    let paragraph: Int
    /// 原句，与这一段的文字逐字一致
    let en: String
    let zh: String
    /// 原句中值得学的表达
    let focus: [String]?
}

/// 阅读轮的读后练习，在学习页里和题目排在一起做。
/// 条目 id：段落概括「<文章 id>#summary」，回译「<文章 id>#bt<序号，从 1 起>」
nonisolated enum ReadingPracticeItem {
    case summary(Chunk)
    case backTranslation(Chunk, number: Int, BackTranslationDrill)

    static func ids(for passage: Chunk) -> [String] {
        ["\(passage.id)#summary"] + (passage.backTranslation ?? []).indices.map { "\(passage.id)#bt\($0 + 1)" }
    }

    init?(id: String, in pack: StudyPack) {
        let parts = id.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, let passage = pack.chunks[parts[0]], passage.isPassage else { return nil }
        if parts[1] == "summary" {
            self = .summary(passage)
        } else if parts[1].hasPrefix("bt"), let n = Int(parts[1].dropFirst(2)),
                  let drills = passage.backTranslation, drills.indices.contains(n - 1) {
            self = .backTranslation(passage, number: n, drills[n - 1])
        } else {
            return nil
        }
    }

    var passage: Chunk {
        switch self {
        case .summary(let p), .backTranslation(let p, _, _): p
        }
    }

    /// 题目导航上的名字
    var label: String {
        switch self {
        case .summary: "段落概括"
        case .backTranslation(_, let n, _): "回译 \(n)"
        }
    }
}

/// 文章的参考概括（AI 编写）
nonisolated struct PassageSummaryReference: Decodable, Sendable {
    /// 每段一句英文概括，与段落一一对应
    let paragraphs: [String]
    /// 全文概括，2–3 句
    let whole: String
}

nonisolated struct Figure: Decodable, Sendable, Identifiable {
    let id: String
    /// book（原书原图，默认）| ai（预处理时画的示意图）
    let origin: String?
    let kind: String?
    let page: [Int]?
    let caption: String
    let image: String
    let transcribedFrom: String?
    /// 原书图的结构化转录，结构随 kind 而定（见 FORMAT.md「figures」）
    let data: YAMLValue?
    /// AI 示意图画了什么
    let description: String?
    /// 图取自本节资料以外的另一本书时写书名，page 是那本书的页码
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id, origin, kind, page, caption, image, data, description, source
        case transcribedFrom = "transcribed_from"
    }

    var isAI: Bool { origin == "ai" }

    /// 把图的内容写成给模型看的文字
    var transcriptText: String {
        if isAI { return description ?? "（无说明）" }
        guard let data, let kind else { return "（无转录）" }
        switch kind {
        case "flowchart":
            let nodes = data["nodes"]?.array ?? []
            let label: [String: String] = Dictionary(uniqueKeysWithValues: nodes.compactMap { n in
                n["id"]?.string.map { ($0, n["label"]?.string ?? $0) }
            })
            var lines = nodes.map { n in
                let name = n["label"]?.string ?? n["id"]?.string ?? ""
                return n["text"]?.string.map { "- \(name)：\($0)" } ?? "- \(name)"
            }
            let edges = (data["edges"]?.array ?? []).compactMap { e -> String? in
                guard let pair = e.array, pair.count == 2,
                      let a = pair[0].string, let b = pair[1].string else { return nil }
                return "\(label[a] ?? a) → \(label[b] ?? b)"
            }
            if !edges.isEmpty { lines.append("箭头：" + edges.joined(separator: "；")) }
            if let note = data["layout_note"]?.string { lines.append("版式：" + note) }
            return lines.joined(separator: "\n")
        case "table":
            let header = (data["header"]?.array ?? []).map { $0.text }
            let rows = (data["rows"]?.array ?? []).map { ($0.array ?? []).map(\.text) }
            return ([header] + rows).map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
        default:
            return data.text
        }
    }
}

/// 结构不固定的 YAML 值（图的转录数据）
nonisolated enum YAMLValue: Decodable, Sendable {
    case string(String)
    case array([YAMLValue])
    case object([String: YAMLValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let a = try? c.decode([YAMLValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: YAMLValue].self) {
            self = .object(o)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    subscript(key: String) -> YAMLValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var array: [YAMLValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// 通用的文字展开
    var text: String {
        switch self {
        case .string(let s): s
        case .array(let a): a.map(\.text).joined(separator: "；")
        case .object(let o): o.keys.sorted().map { "\($0)：\(o[$0]!.text)" }.joined(separator: "\n")
        case .null: ""
        }
    }
}

/// 说法卡：一条要背的固定说法和它指的是什么，像背单词那样翻面自评。
/// 由题目的 phrases 引用，学过那道题后按题放进来（见 PhraseUnlock）
nonisolated struct Phrase: Decodable, Sendable, Identifiable {
    let id: String
    /// 正面：说法，关键词用 **加粗**
    let cue: String
    /// 背面：指的是什么
    let answer: String
    /// 容易串的其他说法卡，背面一起列出
    let confusable: [String]?
    let deprecated: Bool?
}

nonisolated struct Question: Decodable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable {
        case single, combo
        case multiBlank = "multi_blank"
        /// 多选：answer 为全部正确选项的字母（如 "ABD"），全选对才算对
        case multi
        /// 判断：answer 为「正确」或「错误」，没有 options
        case judge
    }

    /// 判断题的两个选项，作答记录里存的就是选项文字
    static let judgeKeys = ["正确", "错误"]

    enum Polarity: String, Decodable, Sendable {
        case positive, negative
    }

    struct Statement: Decodable, Sendable {
        let text: String
        let truth: Bool
        /// 判断错时暴露的知识点；不写时为主考 tests
        let ifMisjudged: [String]?

        enum CodingKeys: String, CodingKey {
            case text, truth
            case ifMisjudged = "if_misjudged"
        }
    }

    struct Blank: Decodable, Sendable {
        let answer: String
        let cue: String
        /// 填错时暴露的知识点；不写时为主考 tests
        let ifWrong: [String]?

        enum CodingKeys: String, CodingKey {
            case answer, cue
            case ifWrong = "if_wrong"
        }
    }

    let id: String
    let num: Int
    /// 资料中没有这道题，由 AI 依据原文出题（题目、答案、解析都是 AI 编写）
    let aiAuthored: Bool
    /// 原书题目的答案或解析由 AI 补写
    let aiWritten: AIWritten?
    /// 题目和解析所在页；习题节里取自课程作业等没有页码的题为空
    let page: [Int]
    let explanationPage: [Int]
    let type: Kind
    let polarity: Polarity
    let stem: String
    /// single：选项文字；combo：选项所含的陈述键（如 ["I", "III"]）
    let options: [String: String]?
    let comboOptions: [String: [String]]?
    let statements: [String: Statement]?
    let sharedOptions: [String: String]?
    let blanks: [Blank]?
    let answer: String?
    let explanation: String
    let requires: [String]
    /// 主考知识点
    let tests: String?
    /// 兼考知识点
    let alsoTests: [String]?
    /// 选了某个错误选项时暴露的知识点；某项不写时为主考 tests
    let distractors: [String: [String]]?
    /// 没选中正确答案本身暴露的知识点；不写时为主考 tests
    let ifMissed: [String]?
    let hint: String?
    let explanationAdds: [String]?
    let figures: [String]?
    let deprecated: Bool?
    /// 阅读理解题所依据的文章（kind: passage 的知识块），做题时显示在题目上方
    let passage: String?
    /// 题目取自本节资料以外的另一本书时写书名（如「1000题第1章」）：页码、题号都是那本书的
    let source: String?
    /// 这道题考到的说法卡：选项字母 → 说法卡 id；题干或解析里出现、不对应选项的在 "-" 下
    let phrases: [String: [String]]?
    /// 每个选项都有说法卡：卡都自评过之后不再进复习队列，只在卡都背牢后回来抽查（见 PhraseUnlock.isRetired）
    let phraseOnly: Bool

    enum CodingKeys: String, CodingKey {
        case id, num, page, type, polarity, stem, options, statements, blanks, answer
        case explanation, requires, tests, distractors, hint, figures, deprecated, passage, source, phrases
        case phraseOnly = "phrase_only"
        case alsoTests = "also_tests"
        case aiAuthored = "ai_authored"
        case aiWritten = "ai_written"
        case explanationPage = "explanation_page"
        case sharedOptions = "shared_options"
        case ifMissed = "if_missed"
        case explanationAdds = "explanation_adds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        num = try c.decode(Int.self, forKey: .num)
        aiAuthored = try c.decodeIfPresent(Bool.self, forKey: .aiAuthored) ?? false
        aiWritten = try c.decodeIfPresent(AIWritten.self, forKey: .aiWritten)
        // 习题节里取自课程作业等没有页码的题不写页码
        page = try c.decodeIfPresent([Int].self, forKey: .page) ?? []
        explanationPage = try c.decodeIfPresent([Int].self, forKey: .explanationPage) ?? []
        type = try c.decode(Kind.self, forKey: .type)
        polarity = try c.decode(Polarity.self, forKey: .polarity)
        stem = try c.decode(String.self, forKey: .stem)
        // combo 的 options 是「选项 → 陈述键列表」，判断题固定为正确 / 错误，其余题型是「选项 → 文字」
        if type == .combo {
            comboOptions = try c.decodeIfPresent([String: [String]].self, forKey: .options)
            options = nil
        } else if type == .judge {
            options = Dictionary(uniqueKeysWithValues: Self.judgeKeys.map { ($0, $0) })
            comboOptions = nil
        } else {
            options = try c.decodeIfPresent([String: String].self, forKey: .options)
            comboOptions = nil
        }
        statements = try c.decodeIfPresent([String: Statement].self, forKey: .statements)
        sharedOptions = try c.decodeIfPresent([String: String].self, forKey: .sharedOptions)
        blanks = try c.decodeIfPresent([Blank].self, forKey: .blanks)
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
        explanation = try c.decode(String.self, forKey: .explanation)
        requires = try c.decode([String].self, forKey: .requires)
        tests = try c.decodeIfPresent(String.self, forKey: .tests)
        alsoTests = try c.decodeIfPresent([String].self, forKey: .alsoTests)
        distractors = try c.decodeIfPresent([String: [String]].self, forKey: .distractors)
        ifMissed = try c.decodeIfPresent([String].self, forKey: .ifMissed)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        explanationAdds = try c.decodeIfPresent([String].self, forKey: .explanationAdds)
        figures = try c.decodeIfPresent([String].self, forKey: .figures)
        deprecated = try c.decodeIfPresent(Bool.self, forKey: .deprecated)
        passage = try c.decodeIfPresent(String.self, forKey: .passage)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        phrases = try c.decodeIfPresent([String: [String]].self, forKey: .phrases)
        phraseOnly = try c.decodeIfPresent(Bool.self, forKey: .phraseOnly) ?? false
    }

    /// 考到的说法卡 id：按选项字母，"-" 下的在最后，不重复
    var phraseIDs: [String] {
        var seen = Set<String>()
        return (phrases ?? [:]).sorted { ($0.key == "-" ? "~" : $0.key) < ($1.key == "-" ? "~" : $1.key) }
            .flatMap(\.value).filter { seen.insert($0).inserted }
    }

    /// 选项字母，按字母序
    var optionKeys: [String] {
        switch type {
        case .single, .multi: (options ?? [:]).keys.sorted()
        case .combo: (comboOptions ?? [:]).keys.sorted()
        case .multiBlank: (sharedOptions ?? [:]).keys.sorted()
        case .judge: Self.judgeKeys
        }
    }

    /// 多选题的正确选项
    var answerSet: Set<String> { Set((answer ?? "").map(String.init)) }

    /// 正确答案的文字：多空题各空答案；多选题「A、B、D」；其余为答案本身
    var answerText: String {
        switch type {
        case .multiBlank: (blanks ?? []).map(\.answer).joined(separator: "、")
        case .multi: answerSet.sorted().joined(separator: "、")
        default: answer ?? ""
        }
    }

    /// 本题考查的知识点，主考在前
    var testedPoints: [String] {
        (tests.map { [$0] } ?? []) + (alsoTests ?? [])
    }

    /// 选项层面标注的知识点，未写时取主考
    func exposed(_ ids: [String]?) -> [String] {
        ids ?? tests.map { [$0] } ?? []
    }

    /// 陈述键，按罗马数字顺序
    var statementKeys: [String] {
        (statements ?? [:]).keys.sorted { Roman.order($0) < Roman.order($1) }
    }
}

nonisolated struct Round: Decodable, Sendable, Identifiable {
    struct Recap: Decodable, Sendable {
        let topic: String
        let from: [String]
    }

    let num: Int
    let title: String?
    let chunks: [String]
    let recap: Recap?
    let questions: [String]

    var id: Int { num }

    /// 阅读轮：本轮的知识块全是文章，不做讲解，直接做题
    func isReading(in pack: StudyPack) -> Bool {
        !chunks.isEmpty && chunks.allSatisfy { pack.chunks[$0]?.isPassage == true }
    }

    /// 习题轮：习题节的轮次，没有知识块也没有回顾，不做讲解，直接做题
    var isExercise: Bool { chunks.isEmpty && recap == nil }

    /// 没有讲解、直接做题的轮：阅读轮和习题轮
    func skipsLecture(in pack: StudyPack) -> Bool { isExercise || isReading(in: pack) }

    /// 学习页按顺序做的条目：本轮的题目；阅读轮在后面接上每篇文章的读后练习（段落概括、各回译句）
    func items(in pack: StudyPack) -> [String] {
        guard isReading(in: pack) else { return questions }
        return questions + chunks.compactMap { pack.chunks[$0] }.flatMap(ReadingPracticeItem.ids)
    }

    func displayTitle(chunkTitles: [String]) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        if isExercise { return "练习" }
        if chunks.isEmpty { return "回顾：\(recap?.topic ?? "")" }
        return chunkTitles.first ?? "本轮讲解"
    }
}

nonisolated enum Roman {
    private static let keys = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII"]
    private static let glyphs = ["Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ"]

    static func order(_ key: String) -> Int { keys.firstIndex(of: key) ?? keys.count }
    static func glyph(_ key: String) -> String {
        keys.firstIndex(of: key).map { glyphs[$0] } ?? key
    }
}
