import Foundation

/// 生词本的 AI 短文复习：AI 用背过的词写一篇英文短文，学生写出标出的词在文中的意思，AI 逐词判断
nonisolated enum VocabPassageAI {
    static let passageSystem = """
    你是考研英语老师。学生在复习背过的生词。请写一篇英文短文，把【生词】里的每个词都自然地用进去。
    要求：
    1. 150–250 词，像考研阅读那样的说明文或议论文，话题自由；
    2. 每个词只用一次，用的是【意思】里的那个意思，可以按语法变形（时态、单复数等）；实在放不进去的词可以不用；
    3. 其余部分只用常见词，让难点只在这些生词上；上下文不要直接解释生词的意思；
    4. 用到某个词时写成 {{编号|文中形式}}，如 {{3|abandoned}}，编号照抄【生词】里的编号。
    只输出一个 JSON 对象，不要其他文字：{"title": "短文标题", "passage": "短文正文，段落之间用 \\n\\n 分隔"}
    """

    static func passageUser(words: [(id: Int, entry: VocabEntry)]) -> String {
        "【生词】\n" + words.map { w in
            var line = "\(w.id). \(w.entry.word)"
            if let m = w.entry.meaning { line += " —— 意思：\(m)" }
            return line + "；原句：\(w.entry.sentence)"
        }.joined(separator: "\n")
    }

    static let gradingSystem = """
    你是考研英语老师。学生读了一篇英文短文，写出其中标出的词在文中的中文意思。请逐个判断：
    - correct：意思对。中文说法不同、词性略有出入，只要理解对就算对；
    - partial：方向大致对，但不准确或只答对一部分；
    - wrong：意思错了，或没写。
    只输出一个 JSON 对象，不要其他文字：{"results": [{"id": 编号, "result": "correct | partial | wrong", "note": "不是 correct 时，一句话给出这个词在文中的准确意思；correct 时省略"}]}
    逐项列出【学生作答】里的每个编号。
    """

    static func gradingUser(passage: VocabPassage, items: [(id: Int, entry: VocabEntry, answer: String)]) -> String {
        var user = "【短文】\(passage.title)\n\(passage.plainText)\n\n【学生作答】\n"
        for item in items {
            let surface = passage.surface(of: item.id) ?? item.entry.word
            var line = "\(item.id). \(surface)"
            if surface.caseInsensitiveCompare(item.entry.word) != .orderedSame { line += "（生词本里是 \(item.entry.word)）" }
            if let m = item.entry.meaning { line += "，生词本释义：\(m)" }
            let answer = item.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            user += line + "；学生写：\(answer.isEmpty ? "（没写）" : answer)\n"
        }
        return user
    }

    struct InvalidOutput: LocalizedError {
        var errorDescription: String? { "AI 的回答不是预期的格式，请重试。" }
    }

    /// 从回答中取出 JSON 对象（容忍前后多余的文字或代码块标记）
    static func jsonObject<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let value = try? JSONDecoder().decode(T.self, from: Data(text[start...end].utf8)) else {
            throw InvalidOutput()
        }
        return value
    }

    /// AI 批改结果：编号 → 结论和说明
    static func parseGrades(_ text: String) throws -> [Int: (result: VocabPassageResult, note: String?)] {
        struct Raw: Decodable {
            struct Item: Decodable { let id: Int; let result: String; let note: String? }
            let results: [Item]
        }
        let raw = try jsonObject(Raw.self, from: text)
        var grades: [Int: (result: VocabPassageResult, note: String?)] = [:]
        for item in raw.results {
            guard let result = VocabPassageResult(rawValue: item.result.trimmingCharacters(in: .whitespaces)) else { continue }
            let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            grades[item.id] = (result, note?.isEmpty == false ? note : nil)
        }
        guard !grades.isEmpty else { throw InvalidOutput() }
        return grades
    }
}

/// AI 写的短文。正文里用到的生词写成 {{编号|文中形式}}
nonisolated struct VocabPassage: Equatable {
    let title: String
    /// 原样保存的正文（带标记）
    let text: String

    enum Segment: Equatable {
        case text(String)
        case word(id: Int, surface: String)
    }

    let segments: [Segment]
    /// 用到的编号，按在文中出现的顺序；同一编号只算第一次
    let usedIDs: [Int]

    /// 解析 AI 的 JSON 回答；validIDs 之外的编号当普通文字。用到的词不到一半时算失败
    init(json text: String, validIDs: Set<Int>) throws {
        struct Raw: Decodable { let title: String?; let passage: String }
        let raw = try VocabPassageAI.jsonObject(Raw.self, from: text)
        try self.init(title: raw.title ?? "", text: raw.passage, validIDs: validIDs)
        guard usedIDs.count * 2 >= validIDs.count else { throw VocabPassageAI.InvalidOutput() }
    }

    /// 从存下来的标题和正文还原
    init(title: String, text: String, validIDs: Set<Int>? = nil) throws {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = text
        let pattern = try NSRegularExpression(pattern: #"\{\{\s*(\d+)\s*\|([^{}]+)\}\}"#)
        let ns = text as NSString
        var segments: [Segment] = []
        var used: [Int] = []
        var cursor = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let id = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let surface = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if m.range.location > cursor {
                segments.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            if validIDs?.contains(id) ?? true, !used.contains(id) {
                segments.append(.word(id: id, surface: surface))
                used.append(id)
            } else {
                segments.append(.text(surface))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { segments.append(.text(ns.substring(from: cursor))) }
        self.segments = segments
        usedIDs = used
    }

    /// 去掉标记的正文
    var plainText: String {
        segments.map {
            switch $0 {
            case .text(let s): s
            case .word(_, let surface): surface
            }
        }.joined()
    }

    /// 一段正文（去掉标记）和其中生词的位置（UTF-16），供划词时用
    struct Paragraph: Equatable {
        var text = ""
        var words: [(id: Int, range: NSRange)] = []

        static func == (a: Paragraph, b: Paragraph) -> Bool {
            a.text == b.text && a.words.map(\.id) == b.words.map(\.id) && a.words.map(\.range) == b.words.map(\.range)
        }
    }

    /// 按空行分段；去掉段首段尾的空白，空段不要
    var paragraphs: [Paragraph] {
        var result = [Paragraph()]
        for segment in segments {
            switch segment {
            case .text(let s):
                for (i, part) in s.components(separatedBy: "\n\n").enumerated() {
                    if i > 0 { result.append(Paragraph()) }
                    result[result.count - 1].text += part
                }
            case .word(let id, let surface):
                let location = (result[result.count - 1].text as NSString).length
                result[result.count - 1].text += surface
                result[result.count - 1].words.append((id, NSRange(location: location, length: (surface as NSString).length)))
            }
        }
        return result.compactMap { p in
            let leading = p.text.prefix { $0.isWhitespace }
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let shift = (String(leading) as NSString).length
            return Paragraph(text: text, words: p.words.map { ($0.id, NSRange(location: $0.range.location - shift, length: $0.range.length)) })
        }
    }

    /// 显示给学生的序号：按在文中出现的顺序从 1 起（编号是挑词时定的，AI 行文时顺序会打乱）
    func number(of id: Int) -> Int { (usedIDs.firstIndex(of: id) ?? 0) + 1 }

    func surface(of id: Int) -> String? {
        for case .word(let i, let surface) in segments where i == id { return surface }
        return nil
    }
}
