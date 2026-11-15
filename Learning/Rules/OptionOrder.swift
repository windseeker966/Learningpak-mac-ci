import Foundation

/// 选项的显示顺序。复习原题时打乱选项，按显示位置重新标字母（显示的 A、B、C… 依次排下来）；
/// 作答、判分、作答记录仍用原题字母，解析里提到的也是原题字母。
nonisolated struct OptionOrder: Equatable, Sendable {
    /// 按显示顺序排列的原题字母
    let keys: [String]
    /// 显示用的字母：原题字母按原顺序依次分给各位置
    let labels: [String]

    /// 不打乱：按原顺序
    init(identity keys: [String]) {
        self.keys = keys
        self.labels = keys
    }

    /// 按给定的显示顺序（原题字母）；和原题字母对不上时不打乱
    init(displayed keys: [String], original: [String]) {
        self.keys = keys.sorted() == original.sorted() ? keys : original
        self.labels = original
    }

    var isShuffled: Bool { keys != labels }

    /// 原题字母在这次显示时的字母
    func label(of key: String) -> String {
        keys.firstIndex(of: key).map { labels[$0] } ?? key
    }

    /// 多个原题字母（如多选题答案）按显示字母排好
    func labels(of keys: some Sequence<String>) -> [String] {
        keys.map(label(of:)).sorted()
    }

    /// 打乱选项。「以上都不对」这类选项留在原位置；选项文字或题面引用了选项字母（如「A和B都对」）时整题不打乱。
    /// 能打乱时保证和原顺序不同
    static func shuffled(keys: [String], texts: [String: String], stem: String,
                         using rng: inout some RandomNumberGenerator) -> OptionOrder {
        let sorted = keys.sorted()
        guard !mentionsOptions(stem), !texts.values.contains(where: mentionsOptions) else {
            return OptionOrder(identity: sorted)
        }
        let movable = sorted.indices.filter { !isPinned(texts[sorted[$0]] ?? "") }
        guard movable.count >= 2 else { return OptionOrder(identity: sorted) }
        var picked = movable.map { sorted[$0] }
        repeat { picked.shuffle(using: &rng) } while picked == movable.map { sorted[$0] }
        var order = sorted
        for (i, pos) in movable.enumerated() { order[pos] = picked[i] }
        return OptionOrder(displayed: order, original: sorted)
    }

    /// 「以上都对」「以上选项都不对」「其他选项都…」这类依赖位置的选项
    static func isPinned(_ text: String) -> Bool {
        ["以上", "上述", "其他选项", "其余选项", "其他都", "其余都"].contains { text.contains($0) }
    }

    /// 引用了选项字母：「选项A」「A项」「A和B」「A、C」等
    static func mentionsOptions(_ text: String) -> Bool {
        text.range(of: #"选项\s*[A-H](?![A-Za-z])|(?<![A-Za-z])[A-H]\s*(选项|项)|(?<![A-Za-z0-9])[A-H]\s*[、和与及或,，]\s*[A-H](?![A-Za-z0-9])"#,
                   options: .regularExpression) != nil
    }

    /// 文字里出现了单独的大写字母 A–H（可能指选项），用来提醒「这里是原题字母」
    static func mentionsLetters(_ text: String) -> Bool {
        text.range(of: #"(?<![A-Za-z])[A-H](?![A-Za-z])"#, options: .regularExpression) != nil
    }


    /// 将解析中明确指向选项的字母改成学生本次看到的编号。
    /// 不改写孤立的 A–H：它们也可能是公式变量或文法符号。
    func relabelOptionReferences(in text: String) -> String {
        guard isShuffled else { return text }
        let pattern = #"选项[ \t]*([A-H])|(?<![A-Za-z0-9])([A-H])[ \t]*项|(?:故选|应选|选择|选|答案[是为]|正确答案[是为])[ \t]*([A-H])(?![A-Za-z0-9])|(?<![A-Za-z0-9])([A-H])(?=[ \t]*(?:正确|错误|不正确|符合|不符合))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let original = text as NSString
        let output = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { continue }
                output.replaceCharacters(in: range, with: label(of: original.substring(with: range)))
            }
        }
        return output as String
    }
}
