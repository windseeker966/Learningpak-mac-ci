import Foundation

/// 中转服务器：手机和 iPad 不在同一个网络时，借它交换加密过的数据块（协议见 learningpack-android/PROTOCOL.md 的「中转」，
/// 加密见 PhoneRelayCrypto）。服务器只是信箱，内容在这里加密、解开。地址存 UserDefaults，设置页「手机复习」里能改
nonisolated enum PhoneRelay {
    static let defaultAddress = "100.114.14.67:47322"
    static let addressKey = "phoneSync.relay"

    enum RelayError: LocalizedError {
        case badAddress(String)
        case http(Int)
        case badBlock

        var errorDescription: String? {
            switch self {
            case .badAddress(let a): "中转服务器地址不对：\(a)"
            case .http(let code): "中转服务器返回错误 \(code)"
            case .badBlock: "中转服务器上的数据解不开：手机和 iPad 的配对密钥可能不一致"
            }
        }
    }

    struct Endpoint {
        var host: String
        var port: UInt16
        var box: String
        var secret: String
    }

    /// 设置里的地址（「主机:端口」，端口默认 47322）和配对密钥
    static func endpoint(secret: String) throws -> Endpoint {
        let saved = UserDefaults.standard.string(forKey: addressKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        let address = saved.isEmpty ? defaultAddress : saved
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = parts.first.map(String.init), !host.isEmpty, parts.count <= 2 else {
            throw RelayError.badAddress(address)
        }
        let port = parts.count == 2 ? UInt16(parts[1]) : 47322
        guard let port else { throw RelayError.badAddress(address) }
        return Endpoint(host: host, port: port, box: PhoneRelayCrypto.mailbox(secret: secret), secret: secret)
    }

    /// 取出 up 或 down 并解开；还没有时为 nil
    static func get(_ slot: String, at e: Endpoint) async throws -> Data? {
        let r = try await PhoneLink.plainRequest(host: e.host, port: e.port, method: "GET", path: "/box/\(e.box)/\(slot)")
        if r.status == 404 { return nil }
        guard r.status == 200 else { throw RelayError.http(r.status) }
        do {
            return try PhoneRelayCrypto.open(r.body, secret: e.secret, purpose: slot)
        } catch {
            throw RelayError.badBlock
        }
    }

    static func put(_ slot: String, _ plain: Data, at e: Endpoint) async throws {
        try await upload(path: "/box/\(e.box)/\(slot)", block: PhoneRelayCrypto.seal(plain, secret: e.secret, purpose: slot), at: e)
    }

    /// 服务器上还没有的图片
    static func missing(_ shas: [String], at e: Endpoint) async throws -> [String] {
        let body = try JSONSerialization.data(withJSONObject: shas)
        let r = try await PhoneLink.plainRequest(host: e.host, port: e.port, method: "POST", path: "/box/\(e.box)/missing", body: body)
        guard r.status == 200 else { throw RelayError.http(r.status) }
        return (try JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["missing"] as? [String] ?? []
    }

    static func putImage(sha: String, _ data: Data, at e: Endpoint) async throws {
        let block = try PhoneRelayCrypto.seal(data, secret: e.secret, purpose: "img:\(sha)")
        try await upload(path: "/box/\(e.box)/img/\(sha)", block: block, at: e, timeout: 60)
    }

    private static func upload(path: String, block: Data, at e: Endpoint, timeout: TimeInterval = 30) async throws {
        let r = try await PhoneLink.plainRequest(host: e.host, port: e.port, method: "PUT", path: path, body: block, timeout: timeout)
        guard r.status / 100 == 2 else { throw RelayError.http(r.status) }
    }
}
