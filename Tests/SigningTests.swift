import Foundation

// 签名描述文件的到期时间：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/Rules/Signing.swift Tests/SigningTests.swift -o /tmp/signing-tests
// /tmp/signing-tests
@main
private enum SigningTests {
    static func main() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>iOS Team Provisioning Profile: com.wind.studypack</string>
            <key>CreationDate</key><date>2026-10-06T13:51:58Z</date>
            <key>ExpirationDate</key><date>2026-10-13T13:51:58Z</date>
        </dict>
        </plist>
        """
        // 前后夹着 CMS 签名的二进制数据
        var data = Data([0x30, 0x80, 0x06, 0x09, 0x2A, 0x86, 0x48, 0xFF, 0x00])
        data.append(Data(xml.utf8))
        data.append(Data([0x00, 0xA0, 0x82, 0xFF, 0x3C, 0x2F]))

        guard let info = SigningProfile.parse(data) else { preconditionFailure("应能解析") }
        let iso = ISO8601DateFormatter()
        precondition(info.name == "iOS Team Provisioning Profile: com.wind.studypack")
        precondition(info.created == iso.date(from: "2026-10-06T13:51:58Z"))
        precondition(info.expires == iso.date(from: "2026-10-13T13:51:58Z"))

        let hour: TimeInterval = 3600
        precondition(SigningProfile.status(info, now: info.expires.addingTimeInterval(-25 * hour)) == .ok)
        precondition(SigningProfile.status(info, now: info.expires.addingTimeInterval(-23 * hour)) == .soon)
        precondition(SigningProfile.status(info, now: info.expires) == .expired)

        precondition(SigningProfile.parse(Data()) == nil, "模拟器没有描述文件")
        precondition(SigningProfile.parse(Data("<?xml no plist".utf8)) == nil)
        let noDate = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>".utf8)
        precondition(SigningProfile.parse(noDate) == nil, "缺到期时间")

        print("SigningTests passed")
    }
}
