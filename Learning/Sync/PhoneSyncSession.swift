import Foundation
import Observation
import SwiftData

/// 和手机复习 App（learningpack-android）同步：取回手机上的作答（PhoneSyncImport）、推送今天的复习题和单词（PhoneSyncPayload）。
/// App 在前台时：回到前台同步一次，之后每分钟一次；作答、背单词保存后两秒内再同步一次，手机上的题单跟着更新。
/// 局域网里找不到手机时改走中转服务器（PhoneRelay），手机自己定时去中转服务器收发。
/// 配对密钥存钥匙串，手机地址存 UserDefaults。协议见 learningpack-android/PROTOCOL.md。由 LearningApp 注入
@MainActor @Observable
final class PhoneSyncSession {
    private static let secretAccount = "phoneSyncSecret"
    private static let hostKey = "phoneSync.host"
    private static let manualHostKey = "phoneSync.manualHost"
    private static let lastSuccessKey = "phoneSync.lastSuccess"
    static let interval: TimeInterval = 60

    /// 钥匙串里的配对密钥；没配对（或取消了配对）时为 nil。MacReport 也用它加密
    static var storedSecret: String? {
        guard let s = Keychain.read(account: secretAccount), !s.isEmpty else { return nil }
        return s
    }

    private(set) var paired = Keychain.read(account: secretAccount) != nil
    private(set) var busy = false
    private(set) var error: String?
    private(set) var lastSuccess = UserDefaults.standard.object(forKey: lastSuccessKey) as? Date
    /// 上次同步的结果，显示在设置页
    private(set) var lastSummary: String?
    /// 上次连上的手机地址
    private(set) var host = UserDefaults.standard.string(forKey: hostKey)
    /// 上次是经中转服务器同步的（局域网里没找到手机）
    private(set) var viaRelay = false
    /// 中转服务器地址（「主机:端口」）；空的用默认地址
    var relayAddress: String = UserDefaults.standard.string(forKey: PhoneRelay.addressKey) ?? "" {
        didSet { UserDefaults.standard.set(relayAddress.trimmingCharacters(in: .whitespaces), forKey: PhoneRelay.addressKey) }
    }
    /// 设置页手填的手机地址；找不到手机时用它
    var manualHost: String = UserDefaults.standard.string(forKey: PhoneSyncSession.manualHostKey) ?? "" {
        didSet { UserDefaults.standard.set(manualHost.trimmingCharacters(in: .whitespaces), forKey: PhoneSyncSession.manualHostKey) }
    }

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var store: PackStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var importing = false
    /// 上次放到中转服务器的题单（不含生成时间）的哈希和时间：没变就不重复上传
    @ObservationIgnored private var relayPushHash: String?
    @ObservationIgnored private var relayPushedAt = Date.distantPast

    // MARK: - 配对

    /// 填配对密钥（手机复习 App 设置里显示的）；格式不对返回 false
    @discardableResult
    func pair(_ input: String) -> Bool {
        guard let secret = PhoneSyncAuth.normalize(input) else { return false }
        Keychain.save(secret, account: Self.secretAccount)
        paired = true
        error = nil
        if context != nil { syncSoon(delay: 0) }
        return true
    }

    func unpair() {
        Keychain.save("", account: Self.secretAccount)
        paired = false
        lastSummary = nil
    }

    // MARK: - 什么时候同步

    func appBecameActive(in context: ModelContext, store: PackStore) {
        self.context = context
        self.store = store
        #if DEBUG
        // 调试：启动参数 -debugPhoneSecret <配对密钥> -debugPhoneHost 127.0.0.1 直接配对、指定手机地址
        // （模拟器连 adb forward 过来的安卓模拟器）
        let d = UserDefaults.standard
        if let secret = d.string(forKey: "debugPhoneSecret") { pair(secret) }
        if let host = d.string(forKey: "debugPhoneHost") { manualHost = host }
        #endif
        observeSaves()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func appEnteredBackground() {
        loop?.cancel()
        loop = nil
        debounce?.cancel()
        debounce = nil
    }

    /// 作答、背单词保存后：复习安排变了，手机上的题单要跟着变
    private func observeSaves() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) {
            [weak self] note in
            let relevant = note.touches([ReviewItem.self, VocabEntry.self, PhraseCard.self])
            MainActor.assumeIsolated {
                guard let self, relevant, !self.importing, self.loop != nil else { return }
                self.syncSoon(delay: 2)
            }
        }
    }

    private func syncSoon(delay: TimeInterval) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: - 同步

    /// 立即同步（设置页的按钮）
    func syncNow() async { await sync(force: true) }

    private func sync(force: Bool = false) async {
        guard paired, !busy, let context, let store, !store.packs.isEmpty,
              let secret = Keychain.read(account: Self.secretAccount) else { return }
        busy = true
        defer { busy = false }
        do {
            // 局域网找不到手机时走中转服务器
            let host = try await lanHost(secret: secret)
            let done = if let host {
                try await syncLAN(host: host, secret: secret, store: store, in: context)
            } else {
                try await syncRelay(secret: secret, store: store, in: context)
            }
            error = nil
            lastSuccess = .now
            UserDefaults.standard.set(lastSuccess, forKey: Self.lastSuccessKey)
            viaRelay = host == nil
            let summary = done.summary
            lastSummary = (host == nil ? "经中转服务器：" : "") + "推送 \(done.built.questionCount) 道题、\(done.built.vocabCount) 个词、\(done.built.phraseCount) 张说法卡"
                + (done.results.isEmpty ? "" : "；取回 \(summary.questions) 道题、\(summary.vocab) 次背单词、\(summary.phrases) 次说法卡、\(summary.passages) 篇短文、\(summary.facts) 轮测速"
                    + (summary.vocabAdded + summary.vocabRemoved == 0 ? "" : "、加入 \(summary.vocabAdded) 个生词、移出 \(summary.vocabRemoved) 个")
                    + (summary.faults == 0 ? "" : "、\(summary.faults) 道标了题目有错")
                    + (summary.marks == 0 ? "" : "、\(summary.marks) 道改了重点或已掌握"))
            if !done.results.isEmpty || done.images > 0 {
                ActivityLog.write("phone_sync", ["pulled": done.results.count, "questions": summary.questions, "vocab": summary.vocab, "phrases": summary.phrases,
                                                 "passages": summary.passages, "skips": summary.skips, "facts": summary.facts,
                                                 "vocab_added": summary.vocabAdded, "vocab_removed": summary.vocabRemoved, "faults": summary.faults,
                                                 "marks": summary.marks,
                                                 "pushed_questions": done.built.questionCount, "images": done.images,
                                                 "via": host == nil ? "relay" : "lan"])
            }
        } catch {
            importing = false
            // 不在一起、没联网是常态：自动同步时不当成错误显示，只有点了「立即同步」才显示
            if force { self.error = error.localizedDescription }
        }
    }

    /// 局域网里连得上的手机地址；连不上为 nil（改走中转）。配对密钥不对的照样抛错：换哪条路都没用
    private func lanHost(secret: String) async throws -> String? {
        #if DEBUG
        // 调试：-debugPhoneRelayOnly YES 不连局域网里的手机，只走中转服务器（模拟器测试时别连上真手机）
        if UserDefaults.standard.bool(forKey: "debugPhoneRelayOnly") { return nil }
        #endif
        do {
            return try await reachableHost(secret: secret)
        } catch let e as PhoneLink.LinkError {
            if case .http(401, _) = e { throw e }
            if case .badSignature = e { throw e }
            return nil
        } catch {
            return nil
        }
    }

    private struct Done {
        var results: [[String: Any]]
        var summary: PhoneSyncImport.Summary
        var built: PhoneSyncPayload.Built
        /// 传了几张图片
        var images: Int
    }

    /// 手机的作答结果和学习时间（/pull 的响应，或中转的 up）写进数据库
    private func importPulled(_ object: [String: Any], store: PackStore, in context: ModelContext)
        -> (results: [[String: Any]], summary: PhoneSyncImport.Summary) {
        let results = object["results"] as? [[String: Any]] ?? []
        if let study = object["study"] as? [String: Any], PhoneStudyTime.save(study) {
            ActivityLog.write("phone_study_time", study)
        }
        importing = true
        let summary = PhoneSyncImport.apply(results, store: store, in: context)
        importing = false
        return (results, summary)
    }

    /// 局域网：直接连手机
    private func syncLAN(host: String, secret: String, store: PackStore, in context: ModelContext) async throws -> Done {
        // 1. 取回手机上的作答
        let pulled = try await PhoneLink.request(host: host, method: "POST", path: "/pull", body: Data("{}".utf8),
                                                 secret: secret)
        guard let object = try JSONSerialization.jsonObject(with: pulled) as? [String: Any] else {
            throw PhoneLink.LinkError.badResponse("pull")
        }
        let (results, summary) = importPulled(object, store: store, in: context)
        // 2. 确认取回的、推送今天的题单和单词
        let built = PhoneSyncPayload.build(ack: results.compactMap { $0["id"] as? String }, store: store, in: context)
        let body = try JSONSerialization.data(withJSONObject: built.json)
        let pushed = try await PhoneLink.request(host: host, method: "POST", path: "/push", body: body, secret: secret)
        let need = (try JSONSerialization.jsonObject(with: pushed) as? [String: Any])?["needImages"] as? [String] ?? []
        // 3. 手机还没有的图片
        for sha in need {
            guard let url = built.images[sha], let data = try? Data(contentsOf: url) else { continue }
            _ = try await PhoneLink.request(host: host, method: "POST", path: "/image?sha=\(sha)", body: data,
                                            secret: secret, timeout: 60)
        }
        relayPushHash = nil
        return Done(results: results, summary: summary, built: built, images: need.count)
    }

    /// 中转服务器：取手机放下的作答（up），放下题单（down）和服务器上还没有的图片。
    /// 题单没变、也没有要确认的结果时，10 分钟内不重复上传
    private func syncRelay(secret: String, store: PackStore, in context: ModelContext) async throws -> Done {
        let relay = try PhoneRelay.endpoint(secret: secret)
        var pulled: (results: [[String: Any]], summary: PhoneSyncImport.Summary) = ([], PhoneSyncImport.Summary())
        if let up = try await PhoneRelay.get("up", at: relay) {
            guard let object = try JSONSerialization.jsonObject(with: up) as? [String: Any] else { throw PhoneRelay.RelayError.badBlock }
            pulled = importPulled(object, store: store, in: context)
        }
        let built = PhoneSyncPayload.build(ack: pulled.results.compactMap { $0["id"] as? String }, store: store, in: context)
        var stable = built.json
        stable["generatedAt"] = nil
        let hash = PhoneSyncAuth.sha256Hex(try JSONSerialization.data(withJSONObject: stable, options: .sortedKeys))
        var images = 0
        if hash != relayPushHash || Date.now.timeIntervalSince(relayPushedAt) > 600 {
            try await PhoneRelay.put("down", try JSONSerialization.data(withJSONObject: built.json), at: relay)
            for sha in try await PhoneRelay.missing(Array(built.images.keys), at: relay) {
                guard let url = built.images[sha], let data = try? Data(contentsOf: url) else { continue }
                try await PhoneRelay.putImage(sha: sha, data, at: relay)
                images += 1
            }
            relayPushHash = hash
            relayPushedAt = .now
        }
        return Done(results: pulled.results, summary: pulled.summary, built: built, images: images)
    }

    /// 先试上次连上的地址；不行再用 Bonjour 找（换了网络，如从宿舍 Wi-Fi 换到热点，手机的地址会变），最后试手填的地址
    private func reachableHost(secret: String) async throws -> String {
        var tried: Set<String> = []
        var lastError: Error = PhoneLink.LinkError.notFound
        func attempt(_ candidate: String?) async throws -> String? {
            guard let candidate, !candidate.isEmpty, tried.insert(candidate).inserted else { return nil }
            do {
                _ = try await PhoneLink.request(host: candidate, method: "GET", path: "/ping", body: Data(),
                                                secret: secret, timeout: 4)
            } catch let e as PhoneLink.LinkError {
                // 配对密钥不对：换地址也没用
                if case .http(401, _) = e { throw e }
                if case .badSignature = e { throw e }
                lastError = e
                return nil
            } catch {
                lastError = error
                return nil
            }
            if host != candidate {
                host = candidate
                UserDefaults.standard.set(candidate, forKey: Self.hostKey)
            }
            return candidate
        }
        if let ok = try await attempt(host) { return ok }
        for found in await PhoneLink.discover() {
            if let ok = try await attempt(found) { return ok }
        }
        if let ok = try await attempt(manualHost.trimmingCharacters(in: .whitespaces)) { return ok }
        throw lastError
    }
}
