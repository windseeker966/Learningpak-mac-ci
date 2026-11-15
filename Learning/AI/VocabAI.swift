import Foundation

/// 划词翻译和生词释义的提示词
enum VocabAI {
    /// 单词或短语：只讲它在这句里的意思，不是原形时说明形态。划词翻译和加入生词本共用，翻译的结果可以直接存为释义
    static let meaningSystem = """
    你是考研英语老师。学生在阅读英文文章（考研真题或网页）时划选了一个单词或短语，请给出它在这句话里的意思，不要翻译整句。
    只输出下面几行，不要其他文字：
    音标：划选内容（按原文中的形式）的 DJ 音标（英式，Daniel Jones 体系），用两条斜线包住，如「/ˈmuːlə/」；短语写整个短语，如「/kɪk ˈbæk/」
    意思：词性和在这句里的中文意思，如「n. 钱（俚语）」「phr. 放松，休息」；是熟词僻义时在末尾加「（熟词僻义）」
    原形：划选的不是原形时写原形、原形的 DJ 音标和形态，如「draw /drɔː/（draws 为第三人称单数）」「child /tʃaɪld/（children 为复数）」；短语写短语原形，如「draw out /drɔː ˈaʊt/（draws out 为第三人称单数）」。划选的就是原形时省略这一行
    其他：最常见的其他一两个意思，没有值得写的就省略这一行
    """

    static func meaningUser(word: String, sentence: String) -> String {
        "划选：\(word)\n原句：\(sentence)"
    }

    /// 解析「意思 / 原形 / 其他」三行；生成中途也可以解析已有的部分
    nonisolated struct Meaning: Equatable {
        var meaning: String?
        var form: String?
        var note: String?
        var phonetic: String?

        init(meaning: String?, form: String?, note: String?, phonetic: String?) {
            self.meaning = meaning
            self.form = form
            self.note = note
            self.phonetic = phonetic
        }

        init(_ text: String) {
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                func value(_ prefix: String) -> String? {
                    guard line.hasPrefix(prefix) else { return nil }
                    let v = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    return v.isEmpty || v == "无" ? nil : v
                }
                if line.hasPrefix("音标：") { phonetic = value("音标：") }
                else if line.hasPrefix("意思：") { meaning = value("意思：") }
                else if line.hasPrefix("原形：") { form = value("原形：") }
                else if line.hasPrefix("其他：") { note = value("其他：") }
                else if line.hasPrefix("补充：") { note = value("补充：") }   // 早期格式
                else if meaning == nil, !line.isEmpty { meaning = line }
            }
        }
    }

    /// 划选的是一句话或更长的片段：翻译这一段
    static let translateSystem = """
    你是考研英语老师。学生在阅读英文文章（考研真题或网页）时划选了一段文字，请给出准确、通顺的中文翻译；是长难句时，再用一行点出句子主干。
    简洁，不要寒暄，不超过 120 字。
    """

    static func translateUser(selection: String, paragraph: String) -> String {
        "【划选】\(selection)\n【所在段落】\(paragraph)"
    }
}

extension VocabEntry {
    /// 生词本里存的释义
    var storedMeaning: VocabAI.Meaning { VocabAI.Meaning(meaning: meaning, form: form, note: note, phonetic: phonetic) }
}
