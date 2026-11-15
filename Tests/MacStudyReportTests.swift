import Foundation

// 给 Mac 的学习时间什么时候发（MacStudyReport）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/MacStudyReport.swift Tests/MacStudyReportTests.swift -o /tmp/mac-study-report-tests
// /tmp/mac-study-report-tests
@main
private enum MacStudyReportTests {
    static func main() {
        typealias R = MacStudyReport
        let t0 = Date(timeIntervalSince1970: 1_762_650_000)
        let last = R.Sent(day: "2026-11-09", minutes: 5, starts: 0, active: true, at: t0)

        precondition(R.due(last: nil, day: "2026-11-09", minutes: 0, starts: 0, active: true, now: t0), "第一次总要发")
        precondition(!R.due(last: last, day: "2026-11-09", minutes: 5, starts: 0, active: true, now: t0 + 600), "什么都没变不发")
        precondition(!R.due(last: last, day: "2026-11-09", minutes: 6, starts: 0, active: true, now: t0 + 60), "只是分钟变了，不到 2 分钟不发")
        precondition(R.due(last: last, day: "2026-11-09", minutes: 7, starts: 0, active: true, now: t0 + 120), "分钟变了，满 2 分钟发")
        precondition(R.due(last: last, day: "2026-11-09", minutes: 10, starts: 1, active: true, now: t0 + 30), "开始次数变了马上发")
        precondition(R.due(last: last, day: "2026-11-09", minutes: 5, starts: 0, active: false, now: t0 + 10), "进后台马上发")
        precondition(R.due(last: last, day: "2026-11-10", minutes: 0, starts: 0, active: true, now: t0 + 10), "换天马上发")

        let body = R.body(day: "2026-11-09", seconds: 1260.7, starts: 1, active: true, now: t0)
        precondition(body["seconds"] as? Int == 1260 && body["starts"] as? Int == 1 && body["sentAt"] as? Int64 == 1_762_650_000_000)
        precondition(body["day"] as? String == "2026-11-09" && body["active"] as? Bool == true && body["v"] as? Int == 1)
        print("MacStudyReportTests 通过")
    }
}
