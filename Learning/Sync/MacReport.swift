import Foundation
import UIKit

/// 把 iPad 上今天的学习时间（IPadStudyTime）放到中转服务器的 study 信箱，给 Mac 上的「上午先学后折腾」提醒
/// （time-tracker-macos 的 morning_guard.py）用，Mac 定时去取。信箱和加密同和手机经中转同步（PhoneRelay，用手机复习的配对密钥，
/// 用途 study）。协议见 learningpack-android/PROTOCOL.md 的「给 Mac 的学习时间」。没配对手机复习时不发。
/// 何时发见 MacStudyReport；StateCheckSession 每次记前台时间后调用（前台约 30 秒一次，进后台时一次）。
/// 发失败下次再试；错误只在和上次不同时写操作日志 mac_report_error，避免每 30 秒记一条
enum MacReport {
    static let slot = "study"

    private static var last: MacStudyReport.Sent?
    private static var sending = false
    private static var lastError: String?

    static func update(active: Bool, now: Date = .now) {
        guard !sending, let secret = PhoneSyncSession.storedSecret else { return }
        let day = StudyPacePolicy.dayKey(now)
        let today = IPadStudyTime.today(day)
        let minutes = Int(today.seconds / 60)
        guard MacStudyReport.due(last: last, day: day, minutes: minutes, starts: today.starts, active: active, now: now) else { return }
        let sent = MacStudyReport.Sent(day: day, minutes: minutes, starts: today.starts, active: active, at: now)
        guard let body = try? JSONSerialization.data(withJSONObject: MacStudyReport.body(
            day: day, seconds: today.seconds, starts: today.starts, active: active, now: now)) else { return }
        sending = true
        // 进后台时那一次：申请一点后台时间把它发完
        let task = active ? UIBackgroundTaskIdentifier.invalid : UIApplication.shared.beginBackgroundTask(withName: "MacReport")
        Task {
            var host = ""
            do {
                let endpoint = try PhoneRelay.endpoint(secret: secret)
                host = endpoint.host
                try await PhoneRelay.put(slot, body, at: endpoint)
                last = sent
                lastError = nil
            } catch {
                let text = error.localizedDescription
                if text != lastError { ActivityLog.write("mac_report_error", ["error": text, "host": host]) }
                lastError = text
            }
            sending = false
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}
