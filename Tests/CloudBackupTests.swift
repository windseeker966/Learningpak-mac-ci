import Foundation

// 数据存档上传到 Google Drive 的规则（CloudBackup）：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/CloudBackup.swift Tests/CloudBackupTests.swift -o /tmp/cloud-backup-tests
// /tmp/cloud-backup-tests
@main
private enum CloudBackupTests {
    static func main() {
        typealias C = CloudBackup
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let hour: TimeInterval = 3600
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * hour) }

        // 什么时候备份
        precondition(C.isDue(lastSuccess: nil, lastAttempt: nil, now: now), "没备份过就备份")
        precondition(!C.isDue(lastSuccess: ago(19), lastAttempt: ago(19.1), now: now), "成功时间是上传那一刻，比开始导出晚")
        precondition(C.isDue(lastSuccess: ago(20), lastAttempt: ago(20), now: now))
        precondition(!C.isDue(lastSuccess: ago(30), lastAttempt: ago(0.5), now: now), "刚失败过，一小时内不重试")
        precondition(C.isDue(lastSuccess: ago(30), lastAttempt: ago(1), now: now))
        precondition(!C.isDue(lastSuccess: nil, lastAttempt: ago(0.5), now: now))

        // 云端留哪几份
        let files = (0..<13).map { C.RemoteFile(id: "\($0)", name: "b\($0)", created: ago(Double($0) * 24)) }
        precondition(C.stale(files.shuffled()).map(\.id) == ["10", "11", "12"])
        precondition(C.stale(Array(files.prefix(10))).isEmpty)
        precondition(C.stale(files, keep: 12).map(\.id) == ["12"])

        // PKCE：期望值用 openssl dgst -sha256 | base64 独立算出
        precondition(C.challenge("abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
        let v = C.verifier()
        precondition(v.count == 43 && v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        precondition(C.verifier() != v)

        print("CloudBackupTests passed")
    }
}
