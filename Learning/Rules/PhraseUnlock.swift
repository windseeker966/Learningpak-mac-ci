import Foundation

/// 说法卡（要背的固定说法）按原题放进来：
/// - 学过的题（第一次做在今天以前）排队，每天按名额一道题一道题放，同一道题的卡一起放，别的题放过的卡跳过；
/// - 放进来时，原题里以前选错过的选项对应的说法先记一次「重来」；
/// - 每个选项都有卡的题（phrase_only），卡都自评过之后退出复习队列；卡都背牢、原题也很久没做时回来抽查一次，
///   抽查做错了，选错的选项对应的卡退回「重来」（missed）
nonisolated enum PhraseUnlock {
    /// 每天最多放进来的新卡数（默认，可在设置里改）
    static let defaultDailyNew = 10
    /// 卡的间隔都到这么多天、原题也这么久没做时，原题回来抽查一次
    static let spotCheckDays = 30.0
    /// 第一次做在这么多天以内的题算刚学的，排在最前（今天学的要明天才放）
    static let recentDays = 3
    /// 错过这么多次的题排在其余已学的题前面
    static let wrongFirst = 2

    /// 排队的一道题
    struct Candidate: Equatable {
        let questionID: String
        /// 所在节在全书里的序号、题号
        let sectionIndex: Int
        let num: Int
        /// 考到的说法卡 id
        let phrases: [String]
        /// 第一次作答的时间
        let firstAnswered: Date
        /// 标了重点
        var starred = false
        /// 答错的次数（不算看过答案后马上重做的）
        var wrongCount = 0
        var lastWrong: Date?
    }

    /// 今天能放的题，按放的顺序：第一次做在今天以前、还有没放进来的卡的题。
    /// 顺序：刚学的（recentDays 天内，后面的节在前）→ 标了重点或错过 wrongFirst 次以上的（最近错的在前）→ 其余按节和题号
    static func queue(_ candidates: [Candidate], introduced: Set<String>, now: Date,
                      calendar: Calendar = .current) -> [Candidate] {
        let today = calendar.startOfDay(for: now)
        let recentStart = calendar.date(byAdding: .day, value: -recentDays, to: today) ?? today
        let open = candidates.filter { c in
            c.firstAnswered < today && c.phrases.contains { !introduced.contains($0) }
        }
        func group(_ c: Candidate) -> Int {
            if c.firstAnswered >= recentStart { return 0 }
            return c.starred || c.wrongCount >= wrongFirst ? 1 : 2
        }
        return open.sorted { a, b in
            let ga = group(a), gb = group(b)
            if ga != gb { return ga < gb }
            switch ga {
            case 0:
                if a.sectionIndex != b.sectionIndex { return a.sectionIndex > b.sectionIndex }
            case 1:
                let la = a.lastWrong ?? .distantPast, lb = b.lastWrong ?? .distantPast
                if la != lb { return la > lb }
                if a.sectionIndex != b.sectionIndex { return a.sectionIndex < b.sectionIndex }
            default:
                if a.sectionIndex != b.sectionIndex { return a.sectionIndex < b.sectionIndex }
            }
            return a.num < b.num
        }
    }

    /// 按顺序挑今天放进来的题，返回每道题新放的卡（已经放进来的跳过，同一批里也不重复）。
    /// 加上下一道题就超过名额时停下；今天还一张都没放时，第一道题超过名额也照放
    static func pick(_ queue: [Candidate], introduced: Set<String>, limit: Int,
                     introducedToday: Int) -> [(questionID: String, phrases: [String])] {
        var have = introduced
        var count = introducedToday
        var out: [(questionID: String, phrases: [String])] = []
        for c in queue {
            let new = c.phrases.filter { !have.contains($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            guard !new.isEmpty else { continue }
            if count + new.count > limit && count > 0 { break }
            if limit <= 0 { break }
            out.append((c.questionID, new))
            have.formUnion(new)
            count += new.count
        }
        return out
    }

    /// 一次作答里选错的选项对应的说法：选了不该选的、没选该选的（单选题答错时，选的那项和正确的那项都算）。
    /// options 是题目的「选项 → 说法卡」，"-" 下的不对应选项，不算
    static func missed(selected: Set<String>, answer: Set<String>, options: [String: [String]]) -> Set<String> {
        var out = Set<String>()
        for (key, ids) in options where key != "-" {
            if selected.contains(key) != answer.contains(key) { out.formUnion(ids) }
        }
        return out
    }

    /// 一张卡现在的状态
    struct CardState {
        /// 自评过（放进来时按原题先记的「重来」不算）
        let selfRated: Bool
        /// 这次的间隔：上次复习到下次到期（天）
        let intervalDays: Double
    }

    /// 每个选项都有卡的题现在是否退出复习队列：卡都放进来、都自评过，才退出；
    /// 卡的间隔都到 spotCheckDays 天、原题也这么久没做时回来抽查（不退出），做过以后又退出。
    /// cards 按题目考到的说法排，没放进来的为 nil
    static func isRetired(cards: [CardState?], lastAnswered: Date?, now: Date) -> Bool {
        guard !cards.isEmpty else { return false }
        let states = cards.compactMap { $0 }
        guard states.count == cards.count, states.allSatisfy(\.selfRated) else { return false }
        let stable = states.allSatisfy { $0.intervalDays >= spotCheckDays }
        let stale = lastAnswered.map { now.timeIntervalSince($0) >= spotCheckDays * 86400 } ?? true
        return !(stable && stale)
    }
}
