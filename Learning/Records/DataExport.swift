import Foundation
import SQLite3

/// 导出数据存档：数据库、Documents 里教辅包以外的数据（主观题笔迹记录、笔迹日志、操作日志等）和设置，
/// 打包成 Documents/Backups/<名称>.zip。
/// 数据库用 SQLite 的 VACUUM INTO 生成一致的单文件副本，App 运行中导出也不会拷到写了一半的状态。
/// Mac 上用 PackFormat/backup.sh 让 App 导出并上传到 Google Drive（deploy.sh 推送前会自动执行，见 DriveBackupSession）。
nonisolated enum DataExport {
    /// 启动时设置这个环境变量（值为存档名）就在打开界面前导出一次，供 backup.sh 使用
    static let environmentKey = "LEARNINGPACK_EXPORT"
    /// 设备上保留的存档数，导出新存档时删掉更旧的
    private static let keepCount = 5

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var directory: URL { documents.appending(path: "Backups") }

    enum ExportError: LocalizedError {
        case database(String)
        case zip(String)

        var errorDescription: String? {
            switch self {
            case .database(let m): "数据库导出失败：\(m)"
            case .zip(let m): "打包失败：\(m)"
            }
        }
    }

    static func defaultName(date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "LearningPack-backup-\(f.string(from: date))"
    }

    /// 存档名只保留字母、数字和 . _ -，避免写出 Backups 目录
    static func sanitized(_ name: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let s = String(name.unicodeScalars.filter { $0.isASCII && allowed.contains($0) })
        return s.isEmpty || s.hasPrefix(".") ? nil : s
    }

    /// 导出到 Documents/Backups/<name>.zip 并返回它的位置。调用前先保存 ModelContext，未保存的修改不会导出。
    /// 先写临时文件再改名，backup.sh 看到 zip 出现即说明已写完。
    static func export(storeURL: URL, name: String = defaultName()) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        let stage = work.appending(path: name)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        try vacuum(storeURL, into: stage.appending(path: storeURL.lastPathComponent))
        // @Attribute(.externalStorage) 的数据（贴进来的作答图片、讲评图片）是数据库旁边 .<库名>_SUPPORT/_EXTERNAL_DATA
        // 里的单独文件，数据库里只存引用，VACUUM INTO 不带它们。文件按 UUID 命名、写入后不再改，紧接着复制即可
        let support = externalSupport(storeURL)
        if fm.fileExists(atPath: support.path) {
            try fm.copyItem(at: support, to: stage.appending(path: support.lastPathComponent))
        }

        // Documents 里教辅包以外的内容都是 App 生成的数据
        let docs = documents
        let stageDocs = stage.appending(path: "Documents")
        try fm.createDirectory(at: stageDocs, withIntermediateDirectories: true)
        var copied: [String] = []
        for item in (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [] {
            let n = item.lastPathComponent
            guard n != directory.lastPathComponent, n != ".DS_Store", n != "Inbox",
                  !fm.fileExists(atPath: item.appending(path: "book.yaml").path) else { continue }
            try fm.copyItem(at: item, to: stageDocs.appending(path: n))
            copied.append(n)
        }

        // 设置（API Key 在钥匙串里，不会导出）
        if let id = Bundle.main.bundleIdentifier, let prefs = UserDefaults.standard.persistentDomain(forName: id) {
            let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
            try data.write(to: stage.appending(path: "preferences.plist"))
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let manifest: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: .now),
            "app": info["CFBundleIdentifier"] as? String ?? "",
            "appVersion": "\(info["CFBundleShortVersionString"] as? String ?? "")(\(info["CFBundleVersion"] as? String ?? ""))",
            "store": storeURL.lastPathComponent,
            // 恢复时与数据库放在同一目录
            "externalData": fm.fileExists(atPath: support.path) ? support.lastPathComponent : "",
            "documents": copied.sorted(),
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: stage.appending(path: "manifest.json"))

        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appending(path: "\(name).zip")
        let partial = directory.appending(path: ".\(name).zip.partial")
        try? fm.removeItem(at: partial)
        try zip(stage, to: partial)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: partial, to: dest)
        prune()
        return dest
    }

    /// SwiftData 外部存储目录：default.store 旁边的 .default_SUPPORT
    static func externalSupport(_ storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appending(path: ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT")
    }

    /// 设备上已有的存档，新的在前
    static func archives() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        func created(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return urls.filter { $0.pathExtension == "zip" }.sorted { created($0) > created($1) }
    }

    private static func prune() {
        let fm = FileManager.default
        for old in archives().dropFirst(keepCount) { try? fm.removeItem(at: old) }
        // backup.sh 读过的结果文件（<名称>.error、<名称>.drive，见 DriveBackupSession）留一天
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey],
                                                options: .skipsHiddenFiles)) ?? []
        for url in urls where ["error", "drive"].contains(url.pathExtension) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date.now.timeIntervalSince(created) > 24 * 3600 { try? fm.removeItem(at: url) }
        }
    }

    /// VACUUM INTO 在一个读事务里写出完整副本（已合并 WAL），不改动原数据库
    private static func vacuum(_ source: URL, into dest: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ExportError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开")
        }
        sqlite3_busy_timeout(db, 5000)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "VACUUM INTO ?", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_bind_text(stmt, 1, dest.path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else {
            throw ExportError.database(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 借助 NSFileCoordinator 的 forUploading 选项把目录压缩成 zip（系统自带，无需第三方库）
    private static func zip(_ folder: URL, to dest: URL) throws {
        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { zipURL in
            do { try FileManager.default.copyItem(at: zipURL, to: dest) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw ExportError.zip(e.localizedDescription) }
    }
}
