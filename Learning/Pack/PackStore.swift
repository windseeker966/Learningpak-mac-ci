import Foundation
import Observation
import Yams

/// 一本已加载的教辅包（只读）
nonisolated struct StudyPack: Identifiable, Sendable {
    let root: URL
    let book: BookFile
    let sections: [SectionFile]
    let knowledgePoints: [String: KnowledgePoint]
    /// 知识点 id，按知识点库中的顺序
    let knowledgePointOrder: [String]
    let questions: [String: Question]
    /// 主观题（综合应用题），id 形如 1.2-C01
    let subjective: [String: SubjectiveQuestion]
    let chunks: [String: Chunk]
    let figures: [String: Figure]
    /// 题目 id → 所在节号
    let questionSection: [String: String]
    /// 说法卡（全书）
    let phrases: [String: Phrase]
    /// 题目不进复习的节（section.review 为 false）
    let unreviewedSections: Set<String>

    var id: String { book.book.id }
    var title: String { book.book.title }
    /// 资料来源的称呼：原书 / 课件 ……
    var sourceLabel: String { book.book.sourceLabel ?? "原书" }
    /// 本书的题能不能 AI 改编（book.ai_variant 为 false 时不能）
    var allowsAIVariant: Bool { book.book.aiVariant != false }

    func section(_ id: String) -> SectionFile? {
        sections.first { $0.section.id == id }
    }

    /// 进复习页的题：选择题和主观题，但阅读理解题不进（文章读过一遍就有印象，重做意义不大），
    /// 标了 review: false 的节的题也不进
    func isReviewable(_ questionID: String) -> Bool {
        if let s = questionSection[questionID], unreviewedSections.contains(s) { return false }
        if let q = questions[questionID] { return q.passage == nil }
        return subjective[questionID] != nil
    }

    /// 讲授某个知识块的节与轮（取第一次讲到它的那一轮）
    func lectureLocation(ofChunk id: String) -> (section: SectionFile, roundIndex: Int)? {
        for s in sections {
            if let i = s.rounds.firstIndex(where: { $0.chunks.contains(id) }) { return (s, i) }
        }
        return nil
    }

    /// 第一次做某道题的位置：所在节、轮与轮内题号（均为下标）
    func questionLocation(_ id: String) -> (section: SectionFile, roundIndex: Int, questionIndex: Int)? {
        for s in sections {
            for (i, r) in s.rounds.enumerated() {
                if let q = r.questions.firstIndex(of: id) { return (s, i, q) }
            }
        }
        return nil
    }

    /// 依据书外补充出的题（requires 里有书外补充的知识块）
    func isSupplementBased(_ requires: [String]?) -> Bool {
        (requires ?? []).contains { chunks[$0]?.isSupplement == true }
    }

    /// 题目上的出处：原书第几页；AI 出题写「依据」；依据书外补充的写明
    /// source：题目取自另一本书时的书名，页码是那本书的；课程作业等没有页码时只写来源
    func questionSource(page: [Int], requires: [String]?, aiAuthored: Bool, source: String? = nil) -> String {
        if let source { return page.isEmpty ? source : "\(source) 第 \(pageText(page)) 页" }
        if isSupplementBased(requires) { return "依据书外补充（延伸\(sourceLabel)第 \(pageText(page)) 页）" }
        return "\(aiAuthored ? "依据" : "")\(sourceLabel)第 \(pageText(page)) 页"
    }

    /// 考到某张说法卡的题，按书里的顺序
    func questions(withPhrase id: String) -> [Question] {
        sections.flatMap(\.questions).filter { $0.phraseIDs.contains(id) }
    }

    /// 背说法卡时一起看的易混说法：卡上标的 confusable 在前，接着是考到它的题里的其他说法
    func confusablePhrases(of id: String) -> [Phrase] {
        var ids = phrases[id]?.confusable ?? []
        for q in questions(withPhrase: id) { ids += q.phraseIDs }
        var seen: Set<String> = [id]
        return ids.filter { seen.insert($0).inserted }.compactMap { phrases[$0] }
    }

    /// 知识点标题，找不到时原样返回 id
    func pointTitle(_ id: String) -> String {
        knowledgePoints[id]?.title ?? id
    }

    func imageURL(for figure: Figure) -> URL {
        root.appending(path: figure.image)
    }

    /// 节的原书 PDF；习题节没有，未随包部署（旧版 deploy.sh、导入时去掉了 PDF）时为 nil
    func sourcePDFURL(for section: SectionFile) -> URL? {
        guard let pdf = section.section.sourcePDF else { return nil }
        let url = root.appending(path: pdf)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func load(from root: URL) throws -> StudyPack {
        let decoder = YAMLDecoder()
        func read<T: Decodable>(_ type: T.Type, _ relative: String) throws -> T {
            let url = root.appending(path: relative)
            let text: String
            do {
                text = try String(contentsOf: url, encoding: .utf8)
            } catch {
                throw PackError.missingFile(relative)
            }
            do {
                return try decoder.decode(type, from: text)
            } catch {
                throw PackError.invalid(relative, String(describing: error))
            }
        }

        let book = try read(BookFile.self, "book.yaml")
        guard book.format == "study-pack", book.schemaVersion == 1 else {
            throw PackError.unsupported(book.format, book.schemaVersion)
        }
        let points = try book.knowledgePoints.map { try read(KnowledgePointFile.self, $0).knowledgePoints } ?? []
        let sections = try book.sections.map { try read(SectionFile.self, $0.file) }

        var questions: [String: Question] = [:]
        var subjective: [String: SubjectiveQuestion] = [:]
        var chunks: [String: Chunk] = [:]
        var figures: [String: Figure] = [:]
        var questionSection: [String: String] = [:]
        var phrases: [String: Phrase] = [:]
        for s in sections {
            for p in s.phrases ?? [] { phrases[p.id] = p }
            for q in s.questions {
                questions[q.id] = q
                questionSection[q.id] = s.section.id
            }
            for q in s.subjective ?? [] {
                subjective[q.id] = q
                questionSection[q.id] = s.section.id
            }
            for c in s.chunks { chunks[c.id] = c }
            for f in s.figures ?? [] { figures[f.id] = f }
        }
        return StudyPack(
            root: root,
            book: book,
            sections: sections,
            knowledgePoints: Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
            knowledgePointOrder: points.map(\.id),
            questions: questions,
            subjective: subjective,
            chunks: chunks,
            figures: figures,
            questionSection: questionSection,
            phrases: phrases,
            unreviewedSections: Set(sections.filter { $0.section.review == false }.map(\.section.id))
        )
    }
}

nonisolated enum PackError: LocalizedError {
    case missingFile(String)
    case invalid(String, String)
    case unsupported(String, Int)
    case managedByMac(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let f): "缺少文件 \(f)"
        case .invalid(let f, let detail): "\(f) 解析失败：\(detail)"
        case .unsupported(let format, let v): "不支持的包格式 \(format) v\(v)"
        case .managedByMac(let title): "《\(title)》是从 Mac 部署到 iPad 的，iPad 上无法替换。请在 Mac 上用 PackFormat/deploy.sh 更新。"
        }
    }
}

/// 管理 Documents 目录下的教辅包。
/// 包目录在「文件」App 的「我的 iPad › LearningPack」里可见，连接 Mac 时也可在访达中拖入。
@Observable
final class PackStore {
    private(set) var packs: [StudyPack] = []
    private(set) var loadErrors: [String] = []
    /// 上次加载时各教辅包 YAML 文件的路径、修改时间和大小
    @ObservationIgnored private var loadedFingerprint: [String]?

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func pack(_ id: String) -> StudyPack? {
        packs.first { $0.id == id }
    }

    /// 启动和回到前台时调用：教辅包的 YAML 没有变化就不重新加载。
    /// 解析全部教辅包要几百毫秒，从 GoodNotes 等切回来时每次都重新加载会卡住界面
    func reloadIfChanged() {
        guard Self.fingerprint() != loadedFingerprint else { return }
        reload()
    }

    func reload() {
        loadedFingerprint = Self.fingerprint()
        var loaded: [StudyPack] = []
        var errors: [String] = []
        for dir in Self.packDirectories() {
            do {
                let pack = try StudyPack.load(from: dir)
                // 同一本书（book.id 相同）出现多份时只保留 book.yaml 较新的一份
                if let i = loaded.firstIndex(where: { $0.id == pack.id }) {
                    let keepNew = Self.modified(pack.root) > Self.modified(loaded[i].root)
                    let dropped = keepNew ? loaded[i].root : pack.root
                    if keepNew { loaded[i] = pack }
                    errors.append("「\(dropped.lastPathComponent)」与另一个文件夹是同一本书（\(pack.id)），已忽略较旧的这份，可在「文件」App 中删除。")
                } else {
                    loaded.append(pack)
                }
            } catch {
                errors.append("\(dir.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        packs = loaded
        loadErrors = errors
    }

    /// Documents 下的教辅包目录（含 book.yaml），按名字排序
    private static func packDirectories() -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return dirs.filter { fm.fileExists(atPath: $0.appending(path: "book.yaml").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 各教辅包 YAML 文件的路径、修改时间和大小，用来判断要不要重新加载
    private static func fingerprint() -> [String] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        var out: [String] = []
        for dir in packDirectories() {
            guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys),
                                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files where url.pathExtension == "yaml" {
                let v = try? url.resourceValues(forKeys: keys)
                out.append("\(url.path)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v?.fileSize ?? 0)")
            }
        }
        return out.sorted()
    }

    private static func modified(_ root: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: root.appending(path: "book.yaml").path)
        return attrs?[.modificationDate] as? Date ?? .distantPast
    }

    /// 从「文件」App 选中的文件夹复制进 Documents/<book.id>。
    /// 同一本书的旧文件夹会被替换（按 id 更新内容，不影响学习记录）。原书 PDF 一并复制，「原文」页要用。
    func importFolder(at source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appending(path: "book.yaml").path) else {
            throw PackError.missingFile("book.yaml（请选择包含 book.yaml 的教辅包文件夹）")
        }
        let incoming = try StudyPack.load(from: source)  // 先验证能加载

        let dest = Self.documents.appending(path: incoming.id)
        do {
            for old in packs where old.id == incoming.id {
                try fm.removeItem(at: old.root)
            }
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            // 用 Mac 上的 deploy.sh（xcrun devicectl）推送的文件归 root 所有，App 无权删除
            throw PackError.managedByMac(incoming.title)
        }
        try fm.copyItem(at: source, to: dest)
        reload()
    }

    func delete(_ pack: StudyPack) throws {
        try FileManager.default.removeItem(at: pack.root)
        reload()
    }
}
