import Foundation

/// Google Drive：OAuth 换取 token、在 App 自己建的文件夹里上传、列出、删除数据存档（REST，不用 Google 的 SDK）。
/// 只申请 drive.file 权限：只能看到、改动这个 App 建的文件。登录界面由视图用 ASWebAuthenticationSession 打开，
/// 流程（何时备份、token 存哪）见 DriveBackupSession。
/// Google Cloud 项目 crucial-botany-480314-m5，iOS 类型的 OAuth 客户端（Bundle ID com.wind.studypack，没有 client secret）
nonisolated enum GoogleDrive {
    static let clientID = "542933438274-vnsa47qs5sd1fqt14nujdduga0dslkat.apps.googleusercontent.com"
    /// iOS 客户端的回调 scheme 是倒过来的 client ID
    static let callbackScheme = "com.googleusercontent.apps.542933438274-vnsa47qs5sd1fqt14nujdduga0dslkat"
    static let redirectURI = "\(callbackScheme):/oauth2redirect"
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let folderName = "LearningPack Backups"

    enum DriveError: LocalizedError {
        case http(Int, String)
        case badResponse(String)
        case signInCancelled

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "Google Drive 返回 \(code)：\(body.prefix(300))"
            case .badResponse(let m): "Google Drive 返回内容无法解析：\(m)"
            case .signInCancelled: "登录没有完成"
            }
        }

        /// refresh token 失效（撤销了授权、改了密码等），要重新登录
        var needsSignIn: Bool {
            if case .http(400, let body) = self { return body.contains("invalid_grant") }
            if case .http(401, _) = self { return true }
            return false
        }
    }

    struct Tokens: Sendable {
        var accessToken: String
        var expiresAt: Date
        var refreshToken: String?
    }

    // MARK: - 登录

    static func authorizationURL(challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // 每次登录都给 refresh token
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    /// 从回调地址取出授权码；state 不符或用户拒绝时抛错
    static func code(from callback: URL, state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw DriveError.badResponse("登录被拒绝：\(error)") }
        guard value("state") == state, let code = value("code") else { throw DriveError.signInCancelled }
        return code
    }

    static func exchange(code: String, verifier: String) async throws -> Tokens {
        try await token([
            "client_id": clientID, "code": code, "code_verifier": verifier,
            "grant_type": "authorization_code", "redirect_uri": redirectURI,
        ])
    }

    static func refresh(_ refreshToken: String) async throws -> Tokens {
        var t = try await token(["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"])
        t.refreshToken = t.refreshToken ?? refreshToken
        return t
    }

    /// 撤销授权（退出登录时）；失败也无妨
    static func revoke(_ token: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func token(_ params: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(params)
        let json = try await send(request)
        guard let access = json["access_token"] as? String else { throw DriveError.badResponse("没有 access_token") }
        let expires = (json["expires_in"] as? Double) ?? 3600
        return Tokens(accessToken: access, expiresAt: .now.addingTimeInterval(expires - 60),
                      refreshToken: json["refresh_token"] as? String)
    }

    private static func form(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    // MARK: - 文件

    /// 登录的账号（设置页显示）
    static func accountEmail(token: String) async throws -> String? {
        let json = try await send(request("https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)", token: token))
        return (json["user"] as? [String: Any])?["emailAddress"] as? String
    }

    /// 存档文件夹的 id：先用记下的 id，找不到（被删了）就按名字找，再没有就新建
    static func folder(known: String?, token: String) async throws -> String {
        if let known {
            let json = try? await send(request("https://www.googleapis.com/drive/v3/files/\(known)?fields=id,trashed", token: token))
            if let json, json["trashed"] as? Bool == false { return known }
        }
        let q = "name = '\(folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        if let id = try await list(query: q, token: token).first?.id { return id }
        var r = request("https://www.googleapis.com/drive/v3/files?fields=id", token: token)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": folderName, "mimeType": "application/vnd.google-apps.folder"])
        guard let id = try await send(r)["id"] as? String else { throw DriveError.badResponse("新建文件夹没有返回 id") }
        return id
    }

    /// 文件夹里的存档
    static func backups(folder: String, token: String) async throws -> [CloudBackup.RemoteFile] {
        try await list(query: "'\(folder)' in parents and trashed = false", token: token)
    }

    /// 可续传上传（先建会话，再一次性 PUT 整个文件）；文件从磁盘直接读，不整个读进内存
    static func upload(_ file: URL, folder: String, token: String) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        var start = request("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable", token: token)
        start.httpMethod = "POST"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("application/zip", forHTTPHeaderField: "X-Upload-Content-Type")
        start.setValue("\(size)", forHTTPHeaderField: "X-Upload-Content-Length")
        start.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": file.lastPathComponent, "parents": [folder], "mimeType": "application/zip",
        ])
        let (_, response) = try await URLSession.shared.data(for: start)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, let location = http?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location) else {
            throw DriveError.http(http?.statusCode ?? -1, "上传会话没有建立")
        }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 600
        let (data, putResponse) = try await URLSession.shared.upload(for: put, fromFile: file)
        try check(data, putResponse)
    }

    static func delete(_ id: String, token: String) async throws {
        var r = request("https://www.googleapis.com/drive/v3/files/\(id)", token: token)
        r.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: r)
        try check(data, response)
    }

    private static func list(query: String, token: String) async throws -> [CloudBackup.RemoteFile] {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [
            .init(name: "q", value: query), .init(name: "spaces", value: "drive"),
            .init(name: "fields", value: "files(id,name,createdTime)"), .init(name: "pageSize", value: "100"),
        ]
        let json = try await send(request(c.url!.absoluteString, token: token))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ((json["files"] as? [[String: Any]]) ?? []).compactMap { f in
            guard let id = f["id"] as? String else { return nil }
            return CloudBackup.RemoteFile(id: id, name: f["name"] as? String ?? "",
                                          created: (f["createdTime"] as? String).flatMap(iso.date(from:)) ?? .distantPast)
        }
    }

    private static func request(_ url: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(data, response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return json
    }

    private static func check(_ data: Data, _ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw DriveError.http(code, String(decoding: data, as: UTF8.self)) }
    }
}
