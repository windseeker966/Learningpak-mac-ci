import Foundation

/// iPad 上今天学了多久（不含手机复习 App）和学习码的配对密钥，存 UserDefaults：
/// StateCheckSession 计时写入（「浏览器」标签页不算）；同步时 PhoneSyncPayload 读出来，做成只含 iPad 部分的学习码推给手机复习 App，
/// 由它转交给时间记录 App 换手机额度（手机上学的由手机复习 App 自己报，所以这里不加 PhoneStudyTime）
enum IPadStudyTime {
    /// 当天的日期（StudyPacePolicy.dayKey，早上 5 点切分）；换天时 StateCheckSession 把秒数、次数清零
    static let dayKey = "studyPace.day"
    static let secondsKey = "studyCode.daySeconds"
    static let startsKey = "studyCode.dayStarts"
    static let secretKey = "studyCode.secret"

    /// iPad 上 day 这天的学习秒数和开始次数；不是这天的为 0
    static func today(_ day: String) -> (seconds: TimeInterval, starts: Int) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: dayKey) == day else { return (0, 0) }
        return (defaults.double(forKey: secondsKey), defaults.integer(forKey: startsKey))
    }

    /// 学习码的配对密钥；还没生成时为 nil（第一次显示学习码或打开设置页「手机额度」时生成）
    static var secret: String? {
        guard let s = UserDefaults.standard.string(forKey: secretKey), !s.isEmpty else { return nil }
        return s
    }
}
