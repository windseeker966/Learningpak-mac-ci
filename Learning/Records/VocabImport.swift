import Foundation
import SwiftData

/// 从 Mac 导入生词（PackFormat/import_vocab.sh）：脚本把生词文件拷到 Documents/VocabImport/<名称>.json，
/// 以环境变量 LEARNINGPACK_VOCAB_IMPORT=<名称> 重启 App，App 启动时导入，结果写到 Documents/VocabImportResults/<名称>.json。
/// devicectl 拷入的文件和目录归 root 所有，App 删不掉也写不进，所以结果另放一个 App 自己建的目录。
/// 文件里带了位置（packID、passageID、paragraph、location、length，如 ftl-mvtr 的 vocab.jsonl）就原样保留；
/// 没带的 packID 为 importPackID，passageID 为空，paragraph 是「词 + 原句」的哈希。同一个 key 只导入一次。
@MainActor
enum VocabImport {
    static let environmentKey = "LEARNINGPACK_VOCAB_IMPORT"

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var inbox: URL { documents.appending(path: "VocabImport") }
    static var results: URL { documents.appending(path: "VocabImportResults") }

    /// 文件里的一个词；只有 word 必填，没有原句时用词本身代替
    struct Item: Decodable {
        let word: String
        var sentence: String?
        var meaning: String?
        var phonetic: String?
        var form: String?
        var note: String?
        /// 出处，显示在生词本里
        var source: String?
        /// 来源程序记下的位置，同 VocabEntry；packID 为空时其余几项不用
        var packID: String?
        var passageID: String?
        var paragraph: Int?
        var location: Int?
        var length: Int?
        /// ISO 8601
        var createdAt: String?
    }

    struct Result: Encodable {
        var added: [String] = []
        var existing: [String] = []
        var error: String?
    }

    /// 启动时设置了环境变量就导入一次
    static func runIfRequested(in context: ModelContext) {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              let name = DataExport.sanitized(raw) else { return }
        var result = Result()
        do {
            let data = try Data(contentsOf: inbox.appending(path: "\(name).json"))
            result = try add(JSONDecoder().decode([Item].self, from: data), in: context)
        } catch {
            result.error = error.localizedDescription
        }
        ActivityLog.write("vocab_import", ["name": name, "added": "\(result.added.count)",
                                           "existing": "\(result.existing.count)", "error": result.error ?? ""])
        let fm = FileManager.default
        try? fm.createDirectory(at: results, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? encoder.encode(result).write(to: results.appending(path: "\(name).json"), options: .atomic)
    }

    /// 按文件里的顺序加入（新词按加入时间先后开始背），已有的跳过
    static func add(_ items: [Item], in context: ModelContext) throws -> Result {
        var keys = Set(try context.fetch(FetchDescriptor<VocabEntry>()).map(\.key))
        let dateParser = ISO8601DateFormatter()
        var result = Result()
        let start = Date.now
        for item in items {
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let sentence = item.sentence?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? word
            let found = (sentence as NSString).range(of: word, options: .caseInsensitive)
            let packID, passageID: String
            let paragraph, location, length: Int
            if let p = item.packID?.nonEmpty, let pa = item.passageID, let pg = item.paragraph,
               let loc = item.location, let len = item.length {
                (packID, passageID, paragraph, location, length) = (p, pa, pg, loc, len)
            } else {
                packID = VocabEntry.importPackID
                passageID = ""
                paragraph = VocabSelection.stableHash("\(word)\n\(sentence)")
                location = found.location == NSNotFound ? 0 : found.location
                length = found.location == NSNotFound ? 0 : found.length
            }
            let key = VocabEntry.key(packID: packID, passageID: passageID, paragraph: paragraph, location: location)
            guard keys.insert(key).inserted else {
                result.existing.append(word)
                continue
            }
            let entry = VocabEntry(packID: packID, passageID: passageID, paragraph: paragraph, location: location,
                                   length: length, word: word, sentence: sentence)
            entry.meaning = item.meaning?.nonEmpty
            entry.phonetic = item.phonetic?.nonEmpty
            entry.form = item.form?.nonEmpty
            entry.note = item.note?.nonEmpty
            entry.sourceTitle = item.source?.nonEmpty
            // 没有加入时间的，同一批依次错开，保持文件里的顺序
            entry.createdAt = item.createdAt.flatMap(dateParser.date(from:))
                ?? start.addingTimeInterval(Double(result.added.count) * 0.001)
            context.insert(entry)
            result.added.append(word)
        }
        try context.save()
        return result
    }
}

private extension String {
    var nonEmpty: String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
