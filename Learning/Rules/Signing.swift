import Foundation

/// App 签名的到期时间：从安装包里的 embedded.mobileprovision 读出。
/// 免费 Apple ID 签的包 7 天后无法打开，需要用 Xcode 重新安装（覆盖安装不丢数据）。
enum SigningProfile {
    struct Info: Equatable {
        var name: String
        var created: Date
        var expires: Date
    }

    /// 描述文件是 CMS 签名包着的 XML plist，取出中间的 plist 解析。
    static func parse(_ data: Data) -> Info? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let expires = plist["ExpirationDate"] as? Date
        else { return nil }
        return Info(name: plist["Name"] as? String ?? "",
                    created: plist["CreationDate"] as? Date ?? expires,
                    expires: expires)
    }

    enum Status: Equatable {
        case ok
        /// 一天内到期
        case soon
        case expired
    }

    static func status(_ info: Info, now: Date) -> Status {
        let left = info.expires.timeIntervalSince(now)
        if left <= 0 { return .expired }
        return left < 24 * 3600 ? .soon : .ok
    }
}
