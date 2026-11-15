import Foundation
import Network

/// 连接手机复习 App（learningpack-android）：用 Bonjour 找到手机，发签名的 HTTP 请求。协议见 learningpack-android/PROTOCOL.md。
/// 手机是服务端（端口固定），iPad 在前台时主动连它；宿舍里两台设备连同一个 Wi-Fi，在外面 iPad 连手机的热点。
/// HTTP 用 Network.framework 直接收发：连的是局域网 IP 上的明文 HTTP，不经过 URLSession 的 ATS 限制
nonisolated enum PhoneLink {
    static let serviceType = "_lpreview._tcp"
    static let port: UInt16 = 47321

    enum LinkError: LocalizedError {
        case notFound
        case timeout
        case badResponse(String)
        case http(Int, String)
        case badSignature

        var errorDescription: String? {
            switch self {
            case .notFound: "没找到手机：确认手机上的复习 App 开着，并和 iPad 在同一个 Wi-Fi 或连着手机热点"
            case .timeout: "连接手机超时"
            case .badResponse(let s): "手机的回应看不懂：\(s)"
            case .http(401, _): "配对密钥不对：在手机复习 App 的设置里看密钥，填到这里"
            case .http(let code, let s): "手机返回错误 \(code)：\(s)"
            case .badSignature: "手机回应的签名不对，配对密钥可能不一致"
            }
        }
    }

    // MARK: - 发现

    /// 用 Bonjour 找手机，返回它在 TXT 记录里报的 IPv4（Wi-Fi 的在前、热点的在后，逗号分隔）；timeout 秒内没找到为空
    static func discover(timeout: TimeInterval = 3) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: .tcp)
            let queue = DispatchQueue(label: "PhoneLink.discover")
            let once = Once()
            @Sendable func finish(_ hosts: [String]) {
                guard once.claim() else { return }
                browser.cancel()
                cont.resume(returning: hosts)
            }
            browser.browseResultsChangedHandler = { results, _ in
                for r in results {
                    if case .bonjour(let txt) = r.metadata, let ip = txt["ip"], !ip.isEmpty {
                        finish(ip.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                        return
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish([]) }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish([]) }
        }
    }

    // MARK: - 请求

    /// 发一个签名的请求，校验响应签名后返回响应体（port 默认是手机的 47321）
    static func request(host: String, port: UInt16 = PhoneLink.port, method: String, path: String, body: Data, secret: String,
                        timeout: TimeInterval = 15) async throws -> Data {
        let time = Int64(Date.now.timeIntervalSince1970 * 1000)
        let sign = PhoneSyncAuth.requestSignature(secret: secret, method: method, path: path, time: time, body: body)
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host):\(port)\r\n"
        head += "Content-Type: \(path.hasPrefix("/image") ? "application/octet-stream" : "application/json")\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "X-LP-Time: \(time)\r\n"
        head += "X-LP-Sign: \(sign)\r\n\r\n"
        let raw = try await exchange(host: host, port: port, request: Data(head.utf8) + body, timeout: timeout)
        let response = try parse(raw)
        guard response.status / 100 == 2 else {
            throw LinkError.http(response.status, String(decoding: response.body.prefix(300), as: UTF8.self))
        }
        guard let t = response.headers["x-lp-time"].flatMap(Int64.init), let s = response.headers["x-lp-sign"],
              PhoneSyncAuth.isFresh(time: t, now: Int64(Date.now.timeIntervalSince1970 * 1000)),
              s == PhoneSyncAuth.responseSignature(secret: secret, time: t, body: response.body)
        else { throw LinkError.badSignature }
        return response.body
    }

    /// 不签名的请求（中转服务器用，内容另外加密过，见 PhoneRelay），返回状态码和响应体
    static func plainRequest(host: String, port: UInt16, method: String, path: String, body: Data = Data(),
                             timeout: TimeInterval = 15) async throws -> (status: Int, body: Data) {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host):\(port)\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        let response = try parse(try await exchange(host: host, port: port, request: Data(head.utf8) + body, timeout: timeout))
        return (response.status, response.body)
    }

    /// 连上、发出请求、收到对方关闭连接为止的全部字节
    private static func exchange(host: String, port: UInt16, request: Data, timeout: TimeInterval) async throws -> Data {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "PhoneLink.request")
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            let received = Buffer()
            @Sendable func finish(_ result: Result<Data, Error>) {
                guard once.claim() else { return }
                connection.cancel()
                cont.resume(with: result)
            }
            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                    if let data { received.append(data) }
                    if let error { finish(.failure(error)); return }
                    if complete { finish(.success(received.data)) } else { receive() }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) } else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                case .waiting(let error):
                    // 没有路由（不在同一个网络、没联网）时一直等着，不如直接失败
                    finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(LinkError.timeout)) }
        }
    }

    private struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private static func parse(_ raw: Data) throws -> Response {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else { throw LinkError.badResponse("没有响应头") }
        let lines = String(decoding: raw[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { throw LinkError.badResponse(lines.first ?? "") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(raw[range.upperBound...])
        if let length = headers["content-length"].flatMap(Int.init), body.count > length { body = body.prefix(length) }
        return Response(status: status, headers: headers, body: body)
    }

    /// 收到的字节（只在连接的队列上读写）
    private final class Buffer: @unchecked Sendable {
        private(set) var data = Data()
        func append(_ d: Data) { data.append(d) }
    }

    /// 回调可能来自不同线程，只认第一次结束
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
