import Foundation
import SwiftData

/// 推给手机复习 App 的内容（协议见 learningpack-android/PROTOCOL.md 的 push）：今天还要做、能在手机上做的复习题
/// （选择题和填空题，不含阅读理解题和综合题），今天要背的词和 AI 短文复习能挑的词，今天要背的说法卡，计算测速用的各事实最近成绩，
/// （只含 iPad 部分的学习码已随手机额度关闭，不再推送。）
/// 题单和复习页一样从今天的计划里取（ReviewScheduler.todayPlan / remaining），顺序也一样
@MainActor
enum PhoneSyncPayload {
    struct Built {
        var json: [String: Any]
        /// 题单里用到的图片：SHA-256 → 文件，手机要哪张就传哪张
        var images: [String: URL]
        var questionCount: Int
        var vocabCount: Int
        var phraseCount: Int
    }

    static func build(ack: [String], store: PackStore, in context: ModelContext, now: Date = .now) -> Built {
        var images: [String: URL] = [:]
        let questions = questionList(store: store, images: &images, in: context, now: now)
        let vocab = vocabLists(in: context, now: now)
        let phrases = phraseList(store: store, in: context)
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.dateFormat = "yyyy-MM-dd"
        var json: [String: Any] = [
            "v": 1,
            "day": day.string(from: now),
            "generatedAt": millis(now),
            "ack": ack,
            "retention": ReviewScheduler.retention,
            "questions": questions,
            "vocab": vocab.json,
            "phrases": ["due": phrases],
            "facts": facts(in: context),
        ]
        // if let code = studyCode(now: now) { json["studyCode"] = code }  // 手机额度已关闭：不再推学习码
        return Built(json: json, images: images, questionCount: questions.count, vocabCount: vocab.dueCount,
                     phraseCount: phrases.count)
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// iPad 上今天学的分钟、开始次数和校验码（同手动输入的学习码，但不含手机上学的）；还没有配对密钥时不发
    static func studyCode(now: Date) -> [String: Any]? {
        guard let secret = IPadStudyTime.secret else { return nil }
        let day = StudyPacePolicy.dayKey(now)
        let today = IPadStudyTime.today(day)
        let minutes = Int(today.seconds / 60)
        return ["day": day, "minutes": minutes, "starts": today.starts,
                "code": StudyCode.code(secret: secret, day: day, minutes: minutes, starts: today.starts)]
    }

    // MARK: - 计算测速

    /// 手机按同样的规则自己抽题（ArithmeticFacts.dailyTest），这里给出今天测过没有、练哪几类、每类几题和每个事实最近一次的成绩
    private static func facts(in context: ModelContext) -> [String: Any] {
        let drills = FactDrill.all(in: context)
        let stats = FactDrill.stats(drills).mapValues { ["seconds": $0.seconds, "correct": $0.correct] as [String: Any] }
        return ["doneToday": FactDrill.doneToday(drills), "perKind": FactDrill.perKind,
                "kinds": FactKind.practiced.map(\.rawValue), "stats": stats]
    }

    // MARK: - 复习题

    private static func questionList(store: PackStore, images: inout [String: URL], in context: ModelContext,
                                     now: Date) -> [[String: Any]] {
        let items = (try? context.fetch(FetchDescriptor<ReviewItem>())) ?? []
        let active = PhraseDeck.reviewable(items, store: store, in: context, now: now)
        let due = active.filter { $0.dueAt <= now }
        let kind: (ReviewItem) -> ReviewPlan.Kind = { ReviewScheduler.kind(of: $0, in: store) }
        let plan = ReviewScheduler.todayPlan(due, all: active, kind: kind, now: now)
        let remaining = ReviewScheduler.remaining(plan: plan, due: due, now: now)
        let estimates = ReviewScheduler.estimatedSeconds(active, kind: kind)
        return remaining.compactMap { item -> [String: Any]? in
            guard let pack = store.pack(item.packID) else { return nil }
            var q: [String: Any] = [
                "key": item.key, "pack": pack.id, "packTitle": pack.title,
                "section": pack.questionSection[item.questionID] ?? "", "id": item.questionID,
                "lastRating": item.reps > 0 ? item.lastRating as Any : NSNull(),
                "estimatedSeconds": estimates[item.key] ?? 30,
            ]
            let mark = QuestionMark.fetch(packID: item.packID, questionID: item.questionID, in: context)
            q["starred"] = mark?.starred == true
            q["mastered"] = WrongBook.isMastered(mark, in: context)
            var used: [String: Any] = [:]
            if let c = pack.questions[item.questionID], c.passage == nil {
                q["kind"] = "choice"
                q["contentHash"] = Grader.contentHash(c)
                q["choice"] = choice(c)
                let ids = (c.figures ?? []) + MarkdownFigures.ids(in: c.explanation)
                for id in ids { addFigure(id, pack: pack, to: &used, images: &images) }
            } else if let s = pack.subjective[item.questionID], s.isBlank {
                q["kind"] = "blank"
                q["contentHash"] = SubjectiveRecords.contentHash(s) ?? ""
                q["blank"] = blank(s, pack: pack, used: &used, images: &images)
                for id in MarkdownFigures.ids(in: s.answer ?? "") + MarkdownFigures.ids(in: s.stem ?? "") {
                    addFigure(id, pack: pack, to: &used, images: &images)
                }
            } else {
                return nil
            }
            q["images"] = used
            return q
        }
    }

    private static func choice(_ c: Question) -> [String: Any] {
        var d: [String: Any] = [
            "type": c.type.rawValue, "polarity": c.polarity.rawValue, "stem": c.stem,
            "explanation": c.explanation, "figures": c.figures ?? [],
            "aiAuthored": c.aiAuthored, "aiWritten": c.aiWritten?.rawValue as Any? ?? NSNull(),
        ]
        if let o = c.options { d["options"] = o }
        if let o = c.comboOptions { d["comboOptions"] = o }
        if let s = c.statements {
            d["statements"] = s.mapValues { ["text": $0.text, "truth": $0.truth] as [String: Any] }
        }
        if let o = c.sharedOptions { d["sharedOptions"] = o }
        if let a = c.explanationAdds, !a.isEmpty { d["explanationAdds"] = a }
        if let b = c.blanks {
            d["blanks"] = b.map { ["answer": $0.answer, "cue": $0.cue] }
        }
        d["answer"] = c.answer as Any? ?? NSNull()
        return d
    }

    private static func blank(_ s: SubjectiveQuestion, pack: StudyPack, used: inout [String: Any],
                              images: inout [String: URL]) -> [String: Any] {
        func image(_ path: String) -> String? {
            guard let sha = sha(of: pack.root.appending(path: path)) else { return nil }
            images[sha] = pack.root.appending(path: path)
            used["img:\(sha)"] = ["sha": sha]
            return "img:\(sha)"
        }
        return [
            "stem": s.stem ?? "",
            "questionImage": s.questionImage.flatMap(image) as Any? ?? NSNull(),
            "parts": s.effectiveParts.map { p in
                ["label": p.label, "answer": p.shownAnswer as Any? ?? NSNull(), "accept": p.accept ?? []] as [String: Any]
            },
            "answer": s.answer ?? "",
            "answerImages": (s.answerImages ?? []).compactMap(image),
            "typed": s.typed,
            "aiAuthored": s.aiAuthored ?? false,
        ]
    }

    private static func addFigure(_ id: String, pack: StudyPack, to used: inout [String: Any], images: inout [String: URL]) {
        guard used[id] == nil, let figure = pack.figures[id] else { return }
        let url = pack.imageURL(for: figure)
        guard let sha = sha(of: url) else { return }
        images[sha] = url
        used[id] = ["sha": sha, "caption": figure.caption]
    }

    /// 图片的 SHA-256，按路径和修改时间缓存（每次同步都要算一遍题单里的图）
    private static var shaCache: [URL: (modified: Date, sha: String)] = [:]

    private static func sha(of url: URL) -> String? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let hit = shaCache[url], hit.modified == modified { return hit.sha }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let sha = PhoneSyncAuth.sha256Hex(data)
        shaCache[url] = (modified, sha)
        return sha
    }

    // MARK: - 单词

    private static func vocabLists(in context: ModelContext, now: Date) -> (json: [String: Any], dueCount: Int) {
        let all = (try? context.fetch(FetchDescriptor<VocabEntry>())) ?? []
        let due = Vocab.dueToday(all)
        let pool = all.filter { !$0.isNew }
        func entry(_ e: VocabEntry) -> [String: Any] {
            ["key": e.key, "word": e.word, "sentence": e.sentence, "meaning": e.meaning as Any? ?? NSNull(),
             "phonetic": e.phonetic as Any? ?? NSNull(), "form": e.form as Any? ?? NSNull(),
             "note": e.note as Any? ?? NSNull(), "isNew": e.isNew, "source": e.sourceTitle as Any? ?? NSNull()]
        }
        let json: [String: Any] = [
            "due": due.map(entry),
            "pool": pool.map(entry),
            "recentPassageKeys": Array(Vocab.recentPassageKeys(now: now, in: context)),
        ]
        return (json, due.count)
    }
}

extension PhoneSyncPayload {
    // MARK: - 说法卡

    /// 今天要背的说法卡（PhraseDeck.dueToday，顺序相同），带上说法、指的是、易混的说法和出处题号。
    /// 教辅包里找不到的卡不发
    static func phraseList(store: PackStore, in context: ModelContext) -> [[String: Any]] {
        PhraseDeck.dueToday(PhraseDeck.all(in: context)).compactMap { c -> [String: Any]? in
            guard let pack = store.pack(c.packID), let p = pack.phrases[c.phraseID] else { return nil }
            let tag = c.isNew ? "new" : c.seededAgain && c.ratings.count == 1 ? "seeded"
                : c.ratings.last == FSRSRating.again.rawValue ? "relearn" : "review"
            return ["key": c.key, "cue": p.cue, "answer": p.answer, "tag": tag,
                    "sources": pack.questions(withPhrase: c.phraseID).map(\.id),
                    "confusable": pack.confusablePhrases(of: c.phraseID).map { ["cue": $0.cue, "answer": $0.answer] }]
        }
    }
}

/// Markdown 里单独一行的 [[图 id]]（同 MarkdownView.figureID 的写法）
nonisolated enum MarkdownFigures {
    static func ids(in text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[[图"), line.hasSuffix("]]") else { continue }
            let id = line.dropFirst(3).dropLast(2).trimmingCharacters(in: CharacterSet(charactersIn: " :：\t"))
            if !id.isEmpty, !out.contains(id) { out.append(id) }
        }
        return out
    }
}
