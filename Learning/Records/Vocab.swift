import Foundation
import NaturalLanguage
import SwiftData

/// 生词本里的一个词：在阅读文章或内置浏览器的网页中划选加入，记下原句和在文中的位置（文章里用来标黄）。
/// 复习按 FSRS 记忆模型安排：每次自评直接更新记忆状态，评分历史另存一份。
@Model
final class VocabEntry: SelfRatedCard {
    /// packID|passageID|段落序号|起点，同一位置只加一次
    @Attribute(.unique) var key: String
    var packID: String
    /// 所在文章（kind: passage 的知识块）；网页里加入的（packID 为 webPackID）是网址
    var passageID: String
    /// 文章第几段（从 0 起；网页里是这一段文字的哈希，见 VocabSelection）以及在这一段文字里的位置（UTF-16）
    var paragraph: Int
    var location: Int
    var length: Int
    /// 划选的原文
    var word: String
    /// 所在的句子
    var sentence: String
    /// AI 给出的、在这句里的意思（如「n. 钱（俚语）」）；生成前为 nil
    var meaning: String?
    /// AI 补充：常见的其他意思
    var note: String?
    /// 划选的不是原形时，AI 说明的形态和原形，如「draw /drɔː/（draws 为第三人称单数）」
    var form: String?
    /// AI 给出的 DJ 音标（划选的形式），如「/ˈmuːlə/」
    var phonetic: String?
    var createdAt: Date
    /// 网页里加入的：网页标题；文章里加入的为 nil
    var sourceTitle: String?

    // FSRS 记忆状态
    var dueAt: Date
    var stability: Double = 0
    var difficulty: Double = 0
    var lastReviewAt: Date?
    var reps: Int = 0
    var lapses: Int = 0
    /// 评分历史（FSRSRating 原始值）及时间
    var ratings: [Int] = []
    var ratedAt: [Date] = []

    init(packID: String, passageID: String, paragraph: Int, location: Int, length: Int,
         word: String, sentence: String) {
        key = Self.key(packID: packID, passageID: passageID, paragraph: paragraph, location: location)
        self.packID = packID
        self.passageID = passageID
        self.paragraph = paragraph
        self.location = location
        self.length = length
        self.word = word
        self.sentence = sentence
        createdAt = .now
        dueAt = .now
    }

    static func key(packID: String, passageID: String, paragraph: Int, location: Int) -> String {
        "\(packID)|\(passageID)|\(paragraph)|\(location)"
    }

    var range: NSRange { NSRange(location: location, length: length) }

    /// 网页里加入的生词的 packID
    static let webPackID = "web"
    var isWeb: Bool { packID == Self.webPackID }

    /// 用 PackFormat/import_vocab.sh 导入的生词的 packID（见 VocabImport）
    static let importPackID = "import"
    var isImported: Bool { packID == Self.importPackID }

    /// AI 短文复习的短文里划词加入的生词的 packID：passageID 是这篇短文的编号，sourceTitle 是「AI 短文：标题」
    static let aiPassagePackID = "aipassage"
}

/// 划选的一段文字：教辅文章的第几段，或网页里的一个段落（packID 为 VocabEntry.webPackID，passageID 是网址）。
/// range 是选区在这一段里的位置（UTF-16）。网页会插入横幅等内容，段落的序号不稳定，改用段落文字的哈希代替序号，
/// 同一段文字再次打开时仍对得上
struct VocabSelection {
    let packID: String
    let passageID: String
    let paragraph: Int
    let paragraphText: String
    let range: NSRange
    /// 网页标题
    var sourceTitle: String? = nil

    init(pack: StudyPack, passage: Chunk, paragraph: Int, range: NSRange) {
        packID = pack.id
        passageID = passage.id
        self.paragraph = paragraph
        paragraphText = passage.paragraphs.indices.contains(paragraph) ? passage.paragraphs[paragraph] : ""
        self.range = range
    }

    init(webURL: String, title: String?, paragraphText: String, range: NSRange) {
        packID = VocabEntry.webPackID
        passageID = webURL
        paragraph = Self.stableHash(paragraphText)
        self.paragraphText = paragraphText
        self.range = range
        sourceTitle = title
    }

    /// FNV-1a（32 位），跨启动不变（String.hashValue 每次启动都不同）
    static func stableHash(_ s: String) -> Int {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return Int(h)
    }

    /// AI 短文复习的短文里的一段。和网页一样用段落文字的哈希代替序号
    init(aiPassageID: String, title: String, paragraphText: String, range: NSRange) {
        packID = VocabEntry.aiPassagePackID
        passageID = aiPassageID
        paragraph = Self.stableHash(paragraphText)
        self.paragraphText = paragraphText
        self.range = range
        sourceTitle = title.isEmpty ? "AI 短文" : "AI 短文：\(title)"
    }

    var key: String { VocabEntry.key(packID: packID, passageID: passageID, paragraph: paragraph, location: range.location) }
    var isValid: Bool { range.location >= 0 && range.location + range.length <= (paragraphText as NSString).length }
    var text: String { isValid ? (paragraphText as NSString).substring(with: range) : "" }
    var sentence: String { Vocab.sentence(in: paragraphText, around: range) }

    /// 给 AI 的所在段落：网页的一个「段落」可能是整篇文章，太长时只取选区前后各 600 字
    var contextParagraph: String {
        let text = paragraphText as NSString
        guard text.length > 1500, isValid else { return paragraphText }
        let start = max(0, range.location - 600)
        let end = min(text.length, range.location + range.length + 600)
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}

@MainActor
enum Vocab {
    /// 每天最多开始背的新词数
    static let dailyNewLimit = 20

    /// 今天要背的词：到期的旧词，加上不超过每日上限的新词（先加入的先背），最后是今天还要再背一次的词（见 relearnToday）
    static func dueToday(_ entries: [VocabEntry]) -> [VocabEntry] {
        let startedToday = entries.filter { e in
            e.ratedAt.first.map { Calendar.current.isDateInToday($0) } == true
        }.count
        let old = entries.filter { !$0.isNew && $0.isDue }.sorted { $0.dueAt < $1.dueAt }
        let new = entries.filter(\.isNew).sorted { $0.createdAt < $1.createdAt }
            .prefix(max(dailyNewLimit - startedToday, 0))
        let relearn = relearnToday(entries).filter { !$0.isDue }
        return old + new + relearn
    }

    /// 今天最后一次自评是「不认识」的词：背单词时排到最后再背一次，中途退出、再进来也还在，直到不再点「不认识」。
    /// 「不认识」把下次复习排到明天，按到期算会漏掉，所以按评分历史找（历史按时间排，手机上的自评也按时间并进来）
    static func relearnToday(_ entries: [VocabEntry]) -> [VocabEntry] {
        entries.filter { e in
            e.ratings.last == FSRSRating.again.rawValue && e.ratedAt.last.map { Calendar.current.isDateInToday($0) } == true
        }
        .sorted { ($0.ratedAt.last ?? .distantPast) < ($1.ratedAt.last ?? .distantPast) }
    }

    /// AI 短文复习用的词：从背过的词里随机挑 count 个（不管到没到期），excluding 里的不挑
    static func passageWords(_ entries: [VocabEntry], count: Int, excluding: Set<String> = []) -> [VocabEntry] {
        Array(entries.filter { !$0.isNew && !excluding.contains($0.key) }.shuffled().prefix(count))
    }

    /// 这么久之内 AI 短文里挑过的词不再挑
    static let passageCooldown: TimeInterval = 3600

    /// 最近 passageCooldown 之内的 AI 短文里挑过的词（VocabEntry.key）。短文写好才记一条记录，生成失败的不算
    static func recentPassageKeys(now: Date = .now, in context: ModelContext) -> Set<String> {
        let since = now.addingTimeInterval(-passageCooldown)
        let recent = (try? context.fetch(FetchDescriptor<VocabPassageAttempt>(
            predicate: #Predicate { $0.createdAt >= since }))) ?? []
        return Set(recent.flatMap { $0.items.map(\.entryKey) })
    }

    /// 背过的词够这么多时才能做 AI 短文复习
    static let passageMinimum = 3

    /// 选中位置所在的句子
    static func sentence(in paragraph: String, around range: NSRange) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        let text = paragraph as NSString
        guard range.location < text.length,
              let r = Range(NSRange(location: range.location, length: 0), in: paragraph) else { return paragraph }
        let sentence = tokenizer.tokenRange(at: r.lowerBound)
        return String(paragraph[sentence]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func remove(_ entry: VocabEntry, in context: ModelContext) {
        context.delete(entry)
        try? context.save()
    }
}

/// AI 短文复习里一个词的结论
nonisolated enum VocabPassageResult: String, Codable, Sendable {
    case correct, partial, wrong

    /// 建议的自评：对 → 认识，部分对 → 模糊，错 → 不认识
    var suggestedRating: FSRSRating {
        switch self {
        case .correct: .good
        case .partial: .hard
        case .wrong: .again
        }
    }
}

/// 一次 AI 短文复习：AI 用背过的词写的短文、学生写的意思、AI 的结论和最后的自评。
/// 每个词的自评同时写进对应 VocabEntry 的 FSRS 记忆状态
@Model
final class VocabPassageAttempt {
    var title: String
    /// 短文正文，用到的生词写成 {{编号|文中形式}}（见 VocabPassage）
    var passage: String
    /// [VocabPassageAttempt.Item]
    var itemsData: Data?
    var usageData: Data?
    var createdAt: Date
    /// 确认自评、计入复习的时间；没确认就关掉的为 nil
    var confirmedAt: Date?
    /// 在手机复习 App 上做的、同步过来的：手机上这条结果的 id（见 PhoneSyncImport）；iPad 上做的为 nil
    var phoneID: String?

    /// 短文里的一个词
    nonisolated struct Item: Codable, Sendable {
        /// 短文里的编号
        var id: Int
        /// 对应 VocabEntry.key
        var entryKey: String
        var word: String
        var answer: String
        /// VocabPassageResult 原始值；AI 批改失败时为 nil
        var result: String?
        var note: String?
        /// 自评（FSRSRating 原始值）
        var rating: Int?

        var verdict: VocabPassageResult? { result.flatMap(VocabPassageResult.init) }
    }

    var items: [Item] {
        get { itemsData.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? [] }
        set { itemsData = try? JSONEncoder().encode(newValue) }
    }

    var usage: [LLMUsage] {
        get { usageData.flatMap { try? JSONDecoder().decode([LLMUsage].self, from: $0) } ?? [] }
        set { usageData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init(title: String, passage: String, items: [Item]) {
        self.title = title
        self.passage = passage
        createdAt = .now
        self.items = items
    }
}
