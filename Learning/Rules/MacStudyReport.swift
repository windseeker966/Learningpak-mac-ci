import Foundation

/// 给 Mac 的学习时间什么时候发（协议见 learningpack-android/PROTOCOL.md 的「给 Mac 的学习时间」）：
/// Mac 上的「上午先学后折腾」提醒（time-tracker-macos 的 morning_guard.py）靠它知道今天在 iPad 上学没学。
/// 换天、开始次数变了、前后台变了马上发；只是分钟数变了时，距上次发出满 minGap 才发。测试见 Tests/MacStudyReportTests.swift
nonisolated enum MacStudyReport {
    struct Sent: Equatable {
        var day: String
        var minutes: Int
        var starts: Int
        var active: Bool
        var at: Date
    }

    static let minGap: TimeInterval = 120

    static func due(last: Sent?, day: String, minutes: Int, starts: Int, active: Bool, now: Date) -> Bool {
        guard let last else { return true }
        if last.day != day || last.starts != starts || last.active != active { return true }
        return last.minutes != minutes && now.timeIntervalSince(last.at) >= minGap
    }

    /// 放进中转服务器 study 信箱的内容
    static func body(day: String, seconds: TimeInterval, starts: Int, active: Bool, now: Date) -> [String: Any] {
        ["v": 1, "sentAt": Int64((now.timeIntervalSince1970 * 1000).rounded()), "day": day,
         "seconds": Int(seconds), "starts": starts, "active": active]
    }
}
