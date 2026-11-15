import Foundation

/// 状态标注：自评当时的学习状态。StateCheck.state 存的是 rawValue
enum StudyState: String, CaseIterable, Codable, Sendable {
    /// low：低落，什么都提不起劲（学和玩都没意思），和身体上的累分开记
    case good, okay, tired, irritated, low

    var label: String {
        switch self {
        case .good: "好"
        case .okay: "一般"
        case .tired: "累"
        case .irritated: "烦"
        case .low: "低落"
        }
    }
}

/// 在什么时候问的。StateCheck.trigger 存的是 rawValue
enum StateCheckTrigger: String, CaseIterable, Codable, Sendable {
    /// 打开 App（已不再问：先做，再问累不累；留给旧记录）
    case launch
    /// 做完今天的第一组复习
    case firstBlock
    /// 离开一阵后回到 App
    case returned
    /// 点了「休息一下」后回到 App
    case afterBreak
    /// 连续学了很久（已不再问：改成休息提醒，见 StudyPacePolicy；留给旧记录）
    case longStudy
    /// 结束一次复习
    case reviewDone
    /// 自己点「记录状态」
    case manual
}

/// 什么时候问一句状态：只在自然的停顿处问，两次之间至少隔 cooldown（点了「休息一下」和自己记录的除外），免得问多了反而烦
enum StateCheckPolicy {
    /// 离开这么久再回来才算「离开一阵」
    static let minAway: TimeInterval = 5 * 60
    static let cooldown: TimeInterval = 30 * 60
    /// 复习了这么久才在结束时问
    static let minReview: TimeInterval = 10 * 60

    /// App 回到前台时问不问、算哪种。away：离开了多久，冷启动为 nil；onBreak：离开前点了「休息一下」。
    /// 冷启动不问：门口多一道闸只会让人更难开始，做完今天的第一组再问（见 afterFirstBlock）
    static func onActivate(away: TimeInterval?, onBreak: Bool, lastPrompt: Date?, now: Date) -> StateCheckTrigger? {
        if onBreak { return .afterBreak }
        guard cooledDown(lastPrompt, now: now) else { return nil }
        guard let away else { return nil }
        return away >= minAway ? .returned : nil
    }

    /// 做完今天的第一组复习时问不问
    static func afterFirstBlock(lastPrompt: Date?, now: Date) -> Bool {
        cooledDown(lastPrompt, now: now)
    }

    /// 结束一次复习时问不问
    static func afterReview(duration: TimeInterval, lastPrompt: Date?, now: Date) -> Bool {
        duration >= minReview && cooledDown(lastPrompt, now: now)
    }

    static func cooledDown(_ lastPrompt: Date?, now: Date) -> Bool {
        lastPrompt.map { now.timeIntervalSince($0) >= cooldown } ?? true
    }
}

/// 学习节奏的提醒：连续学了一段该休息，当天累计学到一定时长该换轻任务、该收工，最近答得不太对劲时问要不要休息
enum StudyReminder: String, CaseIterable, Codable, Sendable {
    /// 连续学了 restAfter
    case rest
    /// 当天累计 2 小时：之后换轻任务
    case dayLight
    /// 当天累计 3 小时：可以收工
    case dayEnough
    /// 最近答得不太对劲（见 StrugglePolicy）：问一句要不要休息
    case struggling
}

/// 什么时候提醒。依据学习数据：一段里 15～45 分钟最专注，之后碰手机和变慢都明显增多；
/// 当天累计 1 小时内很少标「累」「烦」，1～2 小时约一半，2 小时以上大多是。
/// 「学习时长」按 App 在前台的时间算
enum StudyPacePolicy {
    /// 连续学这么久提醒休息
    static let restAfter: TimeInterval = 40 * 60
    /// 离开 App 这么久才算休息过、连续学习重新算；短暂切出去（回消息、查东西）接着算，离开的时间也算在内
    static let breakResets: TimeInterval = 5 * 60
    /// 点「再学 10 分钟」后再提醒
    static let snooze: TimeInterval = 10 * 60
    /// 关掉提醒、没去休息，过这么久再提醒
    static let remindAgain: TimeInterval = 20 * 60
    /// 当天累计到这些时长各提醒一次，按时长从小到大
    static let dayMarks: [(reminder: StudyReminder, seconds: TimeInterval)] = [(.dayLight, 2 * 3600), (.dayEnough, 3 * 3600)]
    /// 一天从早上 5 点算起：熬夜学的算前一天
    static let dayStartHour = 5
    /// 两次计时之间最多记这么久：计时器被系统挂起后醒来，不把挂起的时间都算进去
    static let maxTick: TimeInterval = 120

    /// 回到前台时，连续学习从什么时候算起：离开不到 breakResets 接着算，否则（或从没记过）从现在算。
    /// lastActive：上次在前台的时间，跨启动保留，App 被系统关掉后重新打开也能接上
    static func streakStart(_ previous: Date?, lastActive: Date?, now: Date, scale: Double = 1) -> Date {
        guard let previous, let lastActive, now.timeIntervalSince(lastActive) < breakResets * scale else { return now }
        return previous
    }

    /// 该不该提醒休息：连续学满 restAfter，且过了推迟到的时间
    static func restDue(streakSince: Date, notBefore: Date?, now: Date, scale: Double = 1) -> Bool {
        now.timeIntervalSince(streakSince) >= restAfter * scale && now >= (notBefore ?? .distantPast)
    }

    /// 当天累计到了哪一档还没提醒过；跨过好几档时只提醒最高的一档
    static func dayMarkDue(total: TimeInterval, shown: Set<StudyReminder>, scale: Double = 1) -> StudyReminder? {
        guard let mark = dayMarks.last(where: { total >= $0.seconds * scale }), !shown.contains(mark.reminder) else { return nil }
        return mark.reminder
    }

    /// 提醒过最高一档后，较低的几档也不再提醒
    static func shownAfter(_ reminder: StudyReminder, shown: Set<StudyReminder>) -> Set<StudyReminder> {
        guard let index = dayMarks.firstIndex(where: { $0.reminder == reminder }) else { return shown }
        return shown.union(dayMarks[...index].map(\.reminder))
    }

    /// 这次计时记多少秒
    static func accrued(since last: Date, now: Date) -> TimeInterval {
        min(max(now.timeIntervalSince(last), 0), maxTick)
    }

    /// 属于哪一天（按 dayStartHour 切分），用作当天累计的键
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let shifted = date.addingTimeInterval(-TimeInterval(dayStartHour) * 3600)
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 最近状态可能不好的迹象（见 StrugglePolicy）
enum StruggleSignal: String, CaseIterable, Codable, Sendable {
    /// 答得比平时快很多，又错了几道：多半是在赶、没细看
    case rushing
    /// 最近错得比平时明显多
    case moreWrong
    /// 复习时连着跳过好几道
    case skipping
}

/// 从最近的作答推测状态可能不好，提醒休息。依据 10-09～10-23 的数据：标「累」「烦」之前，错题比平时多、
/// 用时反而变短、跳过题更多；切换标签、切到后台、涂抹擦除没有区别。三条合起来平均每学 2 小时触发约一次，
/// 做题中标「累」「烦」的 9 次里有 7 次之前 30 分钟内触发过，标「好」「一般」的 8 次里有 2 次。
/// 只看这段连续学习里的作答（休息回来不算之前的）；刚答完 settle 内的先不算，留出标记「题目有错」的时间
/// （标了有错的题由调用方去掉：不合理、超范围的题随手答一个再标有错，不该算答错）
enum StrugglePolicy {
    /// 一次选择题作答；usualWrong、usualSeconds 是同一本书、同一模式平时的错题率和用时中位数
    struct Answer: Sendable {
        var at: Date
        var correct: Bool
        var seconds: Double
        var usualWrong: Double
        var usualSeconds: Double
    }

    struct Found: Equatable, Sendable {
        var signal: StruggleSignal
        /// 看了最近几题
        var count: Int
        var wrong: Int
        /// 这几题按平时的错题率应该错几道
        var usualWrong: Double
        /// 用时中位数是平时的几倍
        var speed: Double
        var skips: Int
    }

    /// 看最近多久内的作答
    static let window: TimeInterval = 15 * 60
    /// 答完多久后才算进来
    static let settle: TimeInterval = 2 * 60
    /// 最多看最近几题
    static let lastCount = 10
    /// 至少答了几题才判断
    static let minAnswers = 6
    /// 错得多：至少错几道，且比平时多错几道
    static let minWrong = 4
    static let excessWrong = 2.0
    /// 赶：用时中位数不到平时的这个比例，且至少错几道
    static let rushSpeed = 0.5
    static let rushWrong = 3
    /// 跳过：多久内跳过几道
    static let skipWindow: TimeInterval = 10 * 60
    static let skipCount = 3
    /// 提醒过后，这么久内不再提醒
    static let cooldown: TimeInterval = 30 * 60
    /// 算「平时」至少要有几条记录
    static let minHistory = 20

    /// 平时的错题率和用时中位数；记录太少返回 nil
    static func usual(correct: [Bool], seconds: [Double]) -> (wrong: Double, seconds: Double)? {
        guard correct.count >= minHistory, let median = median(seconds) else { return nil }
        return (Double(correct.filter { !$0 }.count) / Double(correct.count), median)
    }

    /// since：这段连续学习从什么时候开始
    static func check(answers: [Answer], skips: [Date], since: Date, now: Date) -> Found? {
        let from = max(since, now.addingTimeInterval(-window))
        let recent = Array(answers.filter { $0.at > from && $0.at <= now.addingTimeInterval(-settle) }.sorted { $0.at < $1.at }.suffix(lastCount))
        let skipped = skips.filter { $0 > max(since, now.addingTimeInterval(-skipWindow)) && $0 <= now }.count
        let wrong = recent.filter { !$0.correct }.count
        let usualWrong = recent.reduce(0) { $0 + $1.usualWrong }
        let speed = median(recent.map { $0.seconds / max($0.usualSeconds, 1) }) ?? 1
        func found(_ signal: StruggleSignal) -> Found {
            Found(signal: signal, count: recent.count, wrong: wrong, usualWrong: usualWrong, speed: speed, skips: skipped)
        }
        if recent.count >= minAnswers {
            if speed < rushSpeed && wrong >= rushWrong { return found(.rushing) }
            if wrong >= minWrong && Double(wrong) - usualWrong >= excessWrong { return found(.moreWrong) }
        }
        return skipped >= skipCount ? found(.skipping) : nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
