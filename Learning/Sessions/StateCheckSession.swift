import Foundation
import Observation
import SwiftData

/// 状态标注的询问：做完今天的第一组复习、离开一阵后回来、结束一次复习时问一句当时的状态，
/// 也可以自己记录或开始休息（打开 App 时不问：先做，再问累不累）。何时询问见 StateCheckPolicy；询问、作答、关掉都写进操作日志。
/// 学习节奏的提醒也在这里：连续学了 40 分钟提醒休息，当天累计 2 小时、3 小时各提醒一次（见 StudyPacePolicy），
/// 学习时长按 App 在前台的时间算（任一窗口在前台都算，含和 GoodNotes 并排的单独作答窗口，见 LearningApp），
/// 连续学习的起点和当天累计存 UserDefaults，App 被关掉后重新打开能接上。
/// 这段连续学习里答得不太对劲（错得比平时多、答得很快又错、连着跳过，见 StrugglePolicy）时问一句要不要休息。
/// 手机额度的学习码也在这里算（见 StudyCode）：当天的学习分钟数按前台时间算但不含「浏览器」标签页，
/// 一段连续学习满 10 分钟算开始一次，再加上手机复习 App 同步来的当天学习时间（PhoneStudyTime）；配对密钥存 UserDefaults。
/// 由 LearningApp 创建并注入，各个界面共用一个
@MainActor
@Observable
final class StateCheckSession {
    /// 正在询问；nil 表示没有
    private(set) var pending: StateCheckTrigger?
    /// 正在显示的学习节奏提醒；nil 表示没有
    private(set) var reminder: StudyReminder?
    /// 当天累计学习秒数（显示在提醒里）
    private(set) var todaySeconds: TimeInterval = 0
    /// 这段连续学了多久（显示在提醒里）
    private(set) var streakSeconds: TimeInterval = 0
    /// 最近一次发现的不对劲的迹象（显示在提醒里）
    private(set) var struggle: StrugglePolicy.Found?
    /// 学习码用的当天学习秒数（不含浏览器标签页）和开始次数
    private(set) var codeSeconds: TimeInterval = 0
    private(set) var codeStarts = 0

    @ObservationIgnored private var promptedAt: Date?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var backgroundAt: Date?
    @ObservationIgnored private var onBreak = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var reminderShownAt: Date?
    @ObservationIgnored private var context: ModelContext?
    /// 复习时跳过题的时间（只留最近 skipWindow 内的）
    @ObservationIgnored private var skips: [Date] = []
    /// 平时的错题率和用时，按「模式|书」缓存，每天重算
    @ObservationIgnored private var usualCache: [String: (wrong: Double, seconds: Double)] = [:]
    @ObservationIgnored private var usualDay: String?
    /// 正在「浏览器」标签页：这段时间不算进学习码的分钟数（由 RootView 设置）
    @ObservationIgnored private var browsing = false
    #if DEBUG
    @ObservationIgnored private var debugStruggleShown = false
    #endif

    private static let lastPromptKey = "stateCheck.lastPromptAt"
    private static let streakKey = "studyPace.streakSince"
    private static let lastActiveKey = "studyPace.lastActiveAt"
    private static let restNotBeforeKey = "studyPace.restNotBefore"
    private static let dayKey = IPadStudyTime.dayKey
    private static let daySecondsKey = "studyPace.daySeconds"
    private static let dayShownKey = "studyPace.dayShown"
    private static let struggleNotBeforeKey = "studyPace.struggleNotBefore"
    private static let codeSecondsKey = IPadStudyTime.secondsKey
    private static let codeStartsKey = IPadStudyTime.startsKey
    /// 已经算过开始的那段连续学习（存它的起点）
    private static let codeStreakKey = "studyCode.countedStreak"
    static let secretKey = IPadStudyTime.secretKey

    /// 调试：启动参数 -debugPaceMinute 2 把提醒里的 1 分钟缩成 2 秒（40 分钟的休息提醒 80 秒后出现），用于在模拟器上检查
    private let scale: Double = {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "debugPaceMinute")
        if seconds > 0 { return seconds / 60 }
        #endif
        return 1
    }()

    /// 上次自动询问的时间（自己记录的不算），跨启动保留
    private var lastPrompt: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastPromptKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastPromptKey) }
    }

    // MARK: - App 前后台

    /// context 用来查最近的作答（见 checkStruggle）
    func appBecameActive(in context: ModelContext, now: Date = .now) {
        self.context = context
        // 冷启动 away 为 nil；只是短暂进入 inactive（下拉控制中心等）没进后台，算离开 0 秒
        let away = launched ? backgroundAt.map { now.timeIntervalSince($0) } ?? 0 : nil
        launched = true
        backgroundAt = nil
        resumePace(now: now)
        #if DEBUG
        debugStruggle(now: now)
        #endif
        if pending == nil,
           let trigger = StateCheckPolicy.onActivate(away: away, onBreak: onBreak, lastPrompt: lastPrompt, now: now) {
            ask(trigger, now: now)
        }
        onBreak = false
        startTimer()
    }

    /// 进入后台：没回答的询问算没理会，收起
    func appEnteredBackground(now: Date = .now) {
        backgroundAt = now
        timer?.cancel()
        timer = nil
        tickPace(now: now, remindIfDue: false)
        lastTick = nil
        if let pending {
            ActivityLog.write("state_check_ignored", ["trigger": pending.rawValue, "seconds": waited(now)])
            self.pending = nil
        }
        if let reminder {
            // 离开 App 当作去休息了：离开够久连续学习自然重新算，没离开够久回来时再提醒
            ActivityLog.write("study_reminder_ignored", ["reminder": reminder.rawValue, "seconds": reminderWaited(now)])
            self.reminder = nil
        }
    }

    private func startTimer() {
        timer?.cancel()
        let interval = min(30, 30 * scale)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.tickPace(now: .now)
            }
        }
    }

    // MARK: - 学习节奏

    /// 回到前台：接上或重新开始这段连续学习，换了一天就清零当天累计
    private func resumePace(now: Date) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Self.streakKey) as? Date
        let lastActive = defaults.object(forKey: Self.lastActiveKey) as? Date
        let since = StudyPacePolicy.streakStart(previous, lastActive: lastActive, now: now, scale: scale)
        if since != previous {
            defaults.set(since, forKey: Self.streakKey)
            defaults.removeObject(forKey: Self.restNotBeforeKey)
            if let previous, let lastActive {
                ActivityLog.write("study_streak_reset", ["previous_minutes": lastActive.timeIntervalSince(previous) / 60,
                                                         "away_minutes": now.timeIntervalSince(lastActive) / 60])
            }
        }
        defaults.set(now, forKey: Self.lastActiveKey)
        lastTick = now
        tickPace(now: now)
    }

    /// 记一次前台时间，到了就提醒（进后台时只记时间）。同时到时先提醒当天累计，再提醒休息，最后是答得不对劲
    private func tickPace(now: Date, remindIfDue: Bool = true) {
        let defaults = UserDefaults.standard
        let day = StudyPacePolicy.dayKey(now)
        if defaults.string(forKey: Self.dayKey) != day {
            defaults.set(day, forKey: Self.dayKey)
            defaults.set(0.0, forKey: Self.daySecondsKey)
            defaults.removeObject(forKey: Self.dayShownKey)
            defaults.set(0.0, forKey: Self.codeSecondsKey)
            defaults.set(0, forKey: Self.codeStartsKey)
        }
        var total = defaults.double(forKey: Self.daySecondsKey)
        var codeTotal = defaults.double(forKey: Self.codeSecondsKey)
        if let lastTick {
            let accrued = StudyPacePolicy.accrued(since: lastTick, now: now)
            total += accrued
            defaults.set(total, forKey: Self.daySecondsKey)
            if !browsing {
                codeTotal += accrued
                defaults.set(codeTotal, forKey: Self.codeSecondsKey)
            }
        }
        lastTick = now
        defaults.set(now, forKey: Self.lastActiveKey)
        todaySeconds = total / scale
        let since = defaults.object(forKey: Self.streakKey) as? Date ?? now
        streakSeconds = now.timeIntervalSince(since) / scale
        countStart(since: since, now: now, defaults: defaults)
        codeSeconds = codeTotal
        codeStarts = defaults.integer(forKey: Self.codeStartsKey)
        // 给 Mac 的「上午先学后折腾」提醒（进后台时 backgroundAt 已经设好，记成不在前台）
        MacReport.update(active: backgroundAt == nil, now: now)

        guard remindIfDue, reminder == nil else { return }
        let shown = Set((defaults.stringArray(forKey: Self.dayShownKey) ?? []).compactMap(StudyReminder.init(rawValue:)))
        if let mark = StudyPacePolicy.dayMarkDue(total: total, shown: shown, scale: scale) {
            defaults.set(StudyPacePolicy.shownAfter(mark, shown: shown).map(\.rawValue), forKey: Self.dayShownKey)
            remind(mark, now: now)
        } else if StudyPacePolicy.restDue(streakSince: since, notBefore: defaults.object(forKey: Self.restNotBeforeKey) as? Date,
                                          now: now, scale: scale) {
            remind(.rest, now: now)
        } else if let found = checkStruggle(since: since, now: now) {
            struggle = found
            remind(.struggling, now: now)
        }
    }

    private func remind(_ reminder: StudyReminder, now: Date) {
        self.reminder = reminder
        reminderShownAt = now
        var fields: [String: Any] = ["reminder": reminder.rawValue, "today_minutes": todaySeconds / 60,
                                     "streak_minutes": streakSeconds / 60]
        if reminder == .struggling, let struggle {
            UserDefaults.standard.set(now.addingTimeInterval(StrugglePolicy.cooldown), forKey: Self.struggleNotBeforeKey)
            fields.merge(["signal": struggle.signal.rawValue, "answers": struggle.count, "wrong": struggle.wrong,
                          "usual_wrong": struggle.usualWrong, "speed": struggle.speed, "skips": struggle.skips]) { _, new in new }
        } else {
            // 当天累计的提醒也算提醒过休息：不紧接着再弹一次
            UserDefaults.standard.set(now.addingTimeInterval(StudyPacePolicy.remindAgain * scale), forKey: Self.restNotBeforeKey)
        }
        ActivityLog.write("study_reminder", fields)
    }

    // MARK: - 学习码

    /// 这段连续学习满 StudyCode.startAfter 时记一次开始，每段只记一次
    private func countStart(since: Date, now: Date, defaults: UserDefaults) {
        guard StudyCode.countsAsStart(streakSeconds: now.timeIntervalSince(since) / scale) else { return }
        let counted = defaults.object(forKey: Self.codeStreakKey) as? Date
        guard counted != since else { return }
        defaults.set(since, forKey: Self.codeStreakKey)
        defaults.set(defaults.integer(forKey: Self.codeStartsKey) + 1, forKey: Self.codeStartsKey)
        ActivityLog.write("study_code_start", ["starts": defaults.integer(forKey: Self.codeStartsKey)])
    }

    /// 切换到或离开「浏览器」标签页：先把之前的时间按原来的状态记上
    func setBrowsing(_ browsing: Bool, now: Date = .now) {
        guard browsing != self.browsing else { return }
        if lastTick != nil { tickPace(now: now, remindIfDue: false) }
        self.browsing = browsing
    }

    /// 配对密钥：第一次用时生成，手机端填同一个
    var pairingSecret: String {
        if let saved = UserDefaults.standard.string(forKey: Self.secretKey), !saved.isEmpty { return saved }
        let secret = StudyCode.newSecret()
        UserDefaults.standard.set(secret, forKey: Self.secretKey)
        return secret
    }

    /// 重新生成配对密钥（手机端要重新填）
    func regenerateSecret() {
        UserDefaults.standard.set(StudyCode.newSecret(), forKey: Self.secretKey)
        ActivityLog.write("study_code_secret_reset")
    }

    /// 现在的学习码：今天（早上 5 点切分）在 iPad 和手机复习 App 上一共学了多少分钟、开始了几次和校验码；
    /// phoneMinutes 是其中手机上的分钟数（显示用）
    func studyCode(now: Date = .now) -> (day: String, minutes: Int, starts: Int, code: String, phoneMinutes: Int) {
        let day = StudyPacePolicy.dayKey(now)
        let today = UserDefaults.standard.string(forKey: Self.dayKey) == day
        let phone = PhoneStudyTime.today(day)
        let minutes = Int(((today ? codeSeconds : 0) + phone.seconds) / 60)
        let starts = (today ? codeStarts : 0) + phone.starts
        return (day, minutes, starts, StudyCode.code(secret: pairingSecret, day: day, minutes: minutes, starts: starts),
                Int(phone.seconds / 60))
    }

    /// 打开学习码时记一笔，便于和手机端的输入对照
    func studyCodeShown() {
        let c = studyCode()
        ActivityLog.write("study_code_shown", ["minutes": c.minutes, "starts": c.starts, "phone_minutes": c.phoneMinutes])
    }

    // MARK: - 答得不对劲

    /// 复习时跳过了一道（见 ReviewSessionView）
    func questionSkipped(now: Date = .now) {
        skips.append(now)
        skips.removeAll { now.timeIntervalSince($0) > StrugglePolicy.skipWindow }
    }

    /// 这段连续学习里最近的作答有没有不对劲的迹象。提醒过后 cooldown 内、其他提醒刚关掉不久都不查
    private func checkStruggle(since: Date, now: Date) -> StrugglePolicy.Found? {
        guard let context else { return nil }
        if let shown = reminderShownAt, now.timeIntervalSince(shown) < StudyPacePolicy.snooze * scale { return nil }
        if let notBefore = UserDefaults.standard.object(forKey: Self.struggleNotBeforeKey) as? Date, now < notBefore { return nil }
        let from = max(since, now.addingTimeInterval(-StrugglePolicy.window))
        let records = AttemptRecord.since(from, in: context)
        let faulty = faultyQuestions(packIDs: Set(records.map(\.packID)))
        let answers = records.compactMap { r -> StrugglePolicy.Answer? in
            guard let mode = AttemptMode(rawValue: r.mode), mode == .learn || mode == .review,
                  !faulty.contains("\(r.packID)|\(r.questionID)"),
                  let usual = usual(mode: mode, packID: r.packID, now: now) else { return nil }
            return StrugglePolicy.Answer(at: r.createdAt, correct: r.isCorrect, seconds: r.durationSeconds,
                                         usualWrong: usual.wrong, usualSeconds: usual.seconds)
        }
        return StrugglePolicy.check(answers: answers, skips: skips, since: since, now: now)
    }

    /// 标了「题目有错」的题（packID|questionID）：不合理、超范围的题常是随手答一个再标有错，不算进答错和平时的错题率
    private func faultyQuestions(packIDs: Set<String>) -> Set<String> {
        guard let context else { return [] }
        return Set(packIDs.flatMap { QuestionMark.faulty(packID: $0, in: context).values.map(\.key) })
    }

    /// 平时的错题率和用时（不含标了有错的题）：同一本书、同一模式最近 200 条（不够 minHistory 条时用同一模式的全部书）
    private func usual(mode: AttemptMode, packID: String, now: Date) -> (wrong: Double, seconds: Double)? {
        let day = StudyPacePolicy.dayKey(now)
        if usualDay != day {
            usualCache = [:]
            usualDay = day
        }
        let key = "\(mode.rawValue)|\(packID)"
        if let cached = usualCache[key] { return cached }
        guard let context else { return nil }
        let before = now.addingTimeInterval(-StrugglePolicy.window)
        func compute(_ pack: String?) -> (wrong: Double, seconds: Double)? {
            let all = AttemptRecord.latest(mode: mode, packID: pack, before: before, limit: 200, in: context)
            let faulty = faultyQuestions(packIDs: Set(all.map(\.packID)))
            let records = all.filter { !faulty.contains("\($0.packID)|\($0.questionID)") }
            return StrugglePolicy.usual(correct: records.map(\.isCorrect), seconds: records.map(\.durationSeconds))
        }
        guard let value = compute(packID) ?? compute(nil) else { return nil }
        usualCache[key] = value
        return value
    }

    #if DEBUG
    /// 调试：启动参数 -debugStruggle rushing（或 moreWrong、skipping）启动后直接显示这种提醒，检查界面
    private func debugStruggle(now: Date) {
        guard !debugStruggleShown, let raw = UserDefaults.standard.string(forKey: "debugStruggle"),
              let signal = StruggleSignal(rawValue: raw) else { return }
        debugStruggleShown = true
        struggle = StrugglePolicy.Found(signal: signal, count: 10, wrong: 5, usualWrong: 1.8, speed: 0.3, skips: 3)
        remind(.struggling, now: now)
    }
    #endif

    /// 提醒里点「休息一下」：回到 App 时问一次状态；离开够久连续学习重新算
    func takeBreak() {
        respond("break")
        startBreak()
    }

    /// 提醒里点「再学 10 分钟」
    func snoozeRest() {
        UserDefaults.standard.set(Date.now.addingTimeInterval(StudyPacePolicy.snooze * scale), forKey: Self.restNotBeforeKey)
        respond("snooze")
    }

    /// 答得不对劲的提醒里点「还好，继续」
    func keepGoing() {
        respond("continue")
    }

    /// 关掉提醒：过 remindAgain 再提醒休息
    func dismissReminder() {
        respond("dismiss")
    }

    private func respond(_ action: String) {
        guard let reminder else { return }
        var fields: [String: Any] = ["reminder": reminder.rawValue, "action": action, "seconds": reminderWaited(.now)]
        if reminder == .struggling, let struggle { fields["signal"] = struggle.signal.rawValue }
        ActivityLog.write("study_reminder_response", fields)
        self.reminder = nil
    }

    private func reminderWaited(_ now: Date) -> Double {
        reminderShownAt.map { now.timeIntervalSince($0) } ?? 0
    }

    // MARK: - 界面操作

    /// 做完今天的第一组复习（见 ReviewBlockSession.finishBlock）
    func firstBlockFinished(now: Date = .now) {
        guard pending == nil, StateCheckPolicy.afterFirstBlock(lastPrompt: lastPrompt, now: now) else { return }
        ask(.firstBlock, now: now)
    }

    /// 关掉一次复习（startedAt 为打开的时间）
    func reviewClosed(startedAt: Date, now: Date = .now) {
        guard pending == nil,
              StateCheckPolicy.afterReview(duration: now.timeIntervalSince(startedAt), lastPrompt: lastPrompt, now: now)
        else { return }
        ask(.reviewDone, now: now)
    }

    func askManually() {
        ask(.manual, now: .now)
    }

    /// 开始休息：回到 App 时问一次状态
    func startBreak() {
        onBreak = true
        ActivityLog.write("break_start")
    }

    func answer(_ state: StudyState, in context: ModelContext) {
        guard let pending else { return }
        let seconds = waited(.now)
        StateCheck.record(state, trigger: pending, responseSeconds: seconds, in: context)
        ActivityLog.write("state_check", ["state": state.rawValue, "trigger": pending.rawValue, "seconds": seconds])
        self.pending = nil
    }

    func dismiss() {
        guard let pending else { return }
        ActivityLog.write("state_check_dismissed", ["trigger": pending.rawValue, "seconds": waited(.now)])
        self.pending = nil
    }

    private func ask(_ trigger: StateCheckTrigger, now: Date) {
        pending = trigger
        promptedAt = now
        if trigger != .manual { lastPrompt = now }
        ActivityLog.write("state_check_prompt", ["trigger": trigger.rawValue])
    }

    private func waited(_ now: Date) -> Double {
        promptedAt.map { now.timeIntervalSince($0) } ?? 0
    }
}
