import Foundation

/// 键盘输入的填空题：把学生填的内容和教辅包里的 accept 列表比对。
/// 对上了直接判对；对不上的交给 AI 判断是否等价，再由学生自评。
nonisolated enum BlankMatcher {
    /// 规范化：全角转半角（NFKC）、去掉所有空白和包裹的 $、去掉末尾标点、小写
    static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
        t = String(t.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init))
        while t.count >= 2, t.hasPrefix("$"), t.hasSuffix("$") { t = String(t.dropFirst().dropLast()) }
        while let last = t.last, "。.，,；;、".contains(last) { t.removeLast() }
        return t.lowercased()
    }

    /// 能按数值比较时的值：整数、小数、分数 a/b，可带正负号
    static func number(_ normalized: String) -> Double? {
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let a = plain(String(parts[0])), let b = plain(String(parts[1])), b != 0 else { return nil }
            return a / b
        }
        return plain(normalized)
    }

    private static func plain(_ s: String) -> Double? {
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber || "+-.".contains($0) }), s.contains(where: \.isNumber),
              let v = Double(s), v.isFinite else { return nil }
        return v
    }

    /// 填的内容是否与某个可接受答案一致；没填为 false
    static func matches(_ input: String, accept: [String]) -> Bool {
        let a = normalize(input)
        guard !a.isEmpty else { return false }
        let n = number(a)
        return accept.contains { candidate in
            let b = normalize(candidate)
            if a == b { return true }
            guard let n, let m = number(b) else { return false }
            return abs(n - m) <= 1e-9 * max(1, abs(n), abs(m))
        }
    }

    static func isEmpty(_ input: String) -> Bool { normalize(input).isEmpty }
}
