import Foundation

/// 手机复习 App 上今天学了多久（pull 响应里的 study，见 learningpack-android/PROTOCOL.md）：
/// 同步时由 PhoneSyncSession 存下，StateCheckSession 把它加进手机额度的学习码。
/// 手机每次给的都是当天的累计值，同一天里只留最大的一次（手机重装、清数据后从 0 重新算也不会变少）；存 UserDefaults
enum PhoneStudyTime {
    private static let key = "phoneStudy.today"

    /// 收到手机的 study。返回存下的值有没有变
    @discardableResult
    static func save(_ study: [String: Any]) -> Bool {
        guard let day = study["day"] as? String, !day.isEmpty,
              let seconds = (study["seconds"] as? NSNumber)?.doubleValue,
              let starts = (study["starts"] as? NSNumber)?.intValue else { return false }
        let old = today(day)
        let new = (seconds: max(old.seconds, seconds), starts: max(old.starts, starts))
        guard new != old else { return false }
        UserDefaults.standard.set(["day": day, "seconds": new.seconds, "starts": new.starts], forKey: key)
        return true
    }

    /// 手机上 day 这天的学习秒数和开始次数；没有为 0
    static func today(_ day: String) -> (seconds: TimeInterval, starts: Int) {
        guard let saved = UserDefaults.standard.dictionary(forKey: key), saved["day"] as? String == day else { return (0, 0) }
        return ((saved["seconds"] as? NSNumber)?.doubleValue ?? 0, (saved["starts"] as? NSNumber)?.intValue ?? 0)
    }
}
