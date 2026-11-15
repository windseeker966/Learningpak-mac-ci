import Foundation
import Observation
import SwiftData

/// 数据存档备份到 Google Drive：登录（视图打开 Google 的登录页，回调地址交给这里换 token）、
/// 导出（DataExport）后上传到 App 自己建的「LearningPack Backups」文件夹、只留最近 CloudBackup.keepCount 份；
/// 登录后每天第一次打开 App 时自动备份一次（CloudBackup.isDue）。refresh token 存钥匙串，其余存 UserDefaults。
/// backup.sh 让 App 启动时导出的存档也在打开后上传，结果写进 Backups/<存档名>.drive 供脚本读取。
/// 由 LearningApp 注入
@MainActor @Observable
final class DriveBackupSession {
    private static let tokenAccount = "googleDriveRefreshToken"
    private static let emailKey = "driveBackup.email"
    private static let folderKey = "driveBackup.folderID"
    private static let lastSuccessKey = "driveBackup.lastSuccess"
    private static let lastAttemptKey = "driveBackup.lastAttempt"
    private static let lastNameKey = "driveBackup.lastName"

    private(set) var signedIn = Keychain.read(account: tokenAccount) != nil
    private(set) var email = UserDefaults.standard.string(forKey: emailKey)
    private(set) var busy = false
    /// 正在做什么（导出、上传…），显示在设置页
    private(set) var step: String?
    private(set) var error: String?
    private(set) var lastSuccess = UserDefaults.standard.object(forKey: lastSuccessKey) as? Date
    private(set) var lastName = UserDefaults.standard.string(forKey: lastNameKey)

    @ObservationIgnored private var access: GoogleDrive.Tokens?
    @ObservationIgnored private var pending: (state: String, verifier: String)?
    /// backup.sh 启动时导出的存档名，上传后清掉
    @ObservationIgnored private var launchExport = ProcessInfo.processInfo.environment[DataExport.environmentKey]
        .flatMap(DataExport.sanitized)

    // MARK: - 登录

    /// 打开登录页用的地址；回调交给 completeSignIn
    func signInURL() -> URL {
        let state = UUID().uuidString
        let verifier = CloudBackup.verifier()
        pending = (state, verifier)
        error = nil
        return GoogleDrive.authorizationURL(challenge: CloudBackup.challenge(verifier), state: state)
    }

    func completeSignIn(callback: URL, in context: ModelContext) async {
        guard let pending else { return }
        self.pending = nil
        busy = true
        step = "正在登录…"
        defer { busy = false; step = nil }
        do {
            let code = try GoogleDrive.code(from: callback, state: pending.state)
            let tokens = try await GoogleDrive.exchange(code: code, verifier: pending.verifier)
            guard let refresh = tokens.refreshToken else {
                throw GoogleDrive.DriveError.badResponse("没有返回 refresh token")
            }
            Keychain.save(refresh, account: Self.tokenAccount)
            access = tokens
            signedIn = true
            email = try? await GoogleDrive.accountEmail(token: tokens.accessToken)
            UserDefaults.standard.set(email, forKey: Self.emailKey)
            ActivityLog.write("drive_sign_in", [:])
        } catch {
            fail(error, action: "sign_in")
            return
        }
        // 登录后马上备份一次
        busy = false
        await backup(in: context)
    }

    func signInFailed(_ error: Error) {
        pending = nil
        fail(error, action: "sign_in")
    }

    func signOut() {
        let token = Keychain.read(account: Self.tokenAccount)
        Keychain.save("", account: Self.tokenAccount)
        for key in [Self.emailKey, Self.folderKey] { UserDefaults.standard.removeObject(forKey: key) }
        access = nil
        signedIn = false
        email = nil
        error = nil
        ActivityLog.write("drive_sign_out", [:])
        if let token { Task { await GoogleDrive.revoke(token) } }
    }

    // MARK: - 备份

    /// App 回到前台时调用：登录了、到时间了就在后台备份一次
    func backupIfDue(in context: ModelContext, now: Date = .now) {
        if let name = launchExport {
            launchExport = nil
            Task { await uploadLaunchExport(name) }
            return
        }
        let defaults = UserDefaults.standard
        guard signedIn, !busy,
              CloudBackup.isDue(lastSuccess: defaults.object(forKey: Self.lastSuccessKey) as? Date,
                                lastAttempt: defaults.object(forKey: Self.lastAttemptKey) as? Date, now: now) else { return }
        Task { await backup(in: context) }
    }

    /// 导出一份存档并上传，然后删掉云端多出来的旧存档
    func backup(in context: ModelContext) async {
        guard signedIn, !busy, let storeURL = context.container.configurations.first?.url else { return }
        busy = true
        error = nil
        defer { busy = false; step = nil }
        UserDefaults.standard.set(Date.now, forKey: Self.lastAttemptKey)
        do {
            try? context.save()
            step = "正在导出…"
            let file = try await Task.detached { try DataExport.export(storeURL: storeURL) }.value
            try await upload(file)
        } catch {
            fail(error, action: "backup")
        }
    }

    /// 上传 backup.sh 让 App 启动时导出的存档，把结果（ok、skipped: …、error: …）写进 Backups/<name>.drive
    private func uploadLaunchExport(_ name: String) async {
        let marker = DataExport.directory.appending(path: "\(name).drive")
        func finish(_ result: String) {
            try? result.write(to: marker, atomically: true, encoding: .utf8)
        }
        let file = DataExport.directory.appending(path: "\(name).zip")
        guard FileManager.default.fileExists(atPath: file.path) else { return finish("skipped: 没有导出存档") }
        guard signedIn else { return finish("skipped: 没有登录 Google Drive") }
        guard !busy else { return finish("skipped: 正在备份") }
        busy = true
        error = nil
        defer { busy = false; step = nil }
        UserDefaults.standard.set(Date.now, forKey: Self.lastAttemptKey)
        do {
            try await upload(file)
            finish("ok")
        } catch {
            fail(error, action: "backup")
            finish("error: \(self.error ?? error.localizedDescription)")
        }
    }

    /// 上传一份已导出的存档，删掉云端多出来的旧存档，记下成功时间
    private func upload(_ file: URL) async throws {
        let started = Date.now
        step = "正在上传…"
        let token = try await accessToken()
        let folder = try await GoogleDrive.folder(known: UserDefaults.standard.string(forKey: Self.folderKey), token: token)
        UserDefaults.standard.set(folder, forKey: Self.folderKey)
        try await GoogleDrive.upload(file, folder: folder, token: token)
        step = "正在清理旧存档…"
        var removed = 0
        if let files = try? await GoogleDrive.backups(folder: folder, token: token) {
            for old in CloudBackup.stale(files) where (try? await GoogleDrive.delete(old.id, token: token)) != nil {
                removed += 1
            }
        }
        lastSuccess = started
        lastName = file.lastPathComponent
        UserDefaults.standard.set(started, forKey: Self.lastSuccessKey)
        UserDefaults.standard.set(lastName, forKey: Self.lastNameKey)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        ActivityLog.write("drive_backup", ["name": file.lastPathComponent, "bytes": size, "removed": removed,
                                           "seconds": Date.now.timeIntervalSince(started)])
    }

    private func accessToken() async throws -> String {
        if let access, access.expiresAt > .now { return access.accessToken }
        guard let refresh = Keychain.read(account: Self.tokenAccount) else { throw GoogleDrive.DriveError.signInCancelled }
        let tokens = try await GoogleDrive.refresh(refresh)
        access = tokens
        return tokens.accessToken
    }

    private func fail(_ error: Error, action: String) {
        let drive = error as? GoogleDrive.DriveError
        if drive?.needsSignIn == true {
            // 授权失效：清掉，设置页显示重新登录
            Keychain.save("", account: Self.tokenAccount)
            access = nil
            signedIn = false
            self.error = "Google 授权已失效，请重新登录"
        } else if case .signInCancelled = drive {
            self.error = nil
        } else {
            self.error = error.localizedDescription
        }
        ActivityLog.write("drive_error", ["action": action, "error": error.localizedDescription])
    }
}
