import Foundation
import SwiftData

/// 把手机复习 App 取回的作答结果写进数据库（协议见 learningpack-android/PROTOCOL.md 的 pull）：
/// 选择题、填空题写成复习模式的作答记录并重算复习安排，背单词和 AI 短文复习的自评计入生词的记忆状态，说法卡的自评计入卡的记忆状态；
/// AI 短文里划词加入的生词加进生词本，背单词时移出的从生词本删掉；做题时标的「题目有错」「重点」「已掌握」记进 QuestionMark。
/// 按结果的 id 去重（记在各条记录的 phoneID 上），同一批结果重复导入不会多出记录。
/// 对错由 iPad 用当前的题目重新判，不信任手机给的对错
@MainActor
enum PhoneSyncImport {
    struct Summary {
        var questions = 0
        var vocab = 0
        var phrases = 0
        var passages = 0
        var skips = 0
        var facts = 0
        var vocabAdded = 0
        var vocabRemoved = 0
        var faults = 0
        var marks = 0
    }

    /// results：pull 响应里的 results。返回各类导入了几条（重复的不算）
    static func apply(_ results: [[String: Any]], store: PackStore, in context: ModelContext) -> Summary {
        var summary = Summary()
        var refresh: Set<String> = []
        // 重点、已掌握放到最后：要和这道题全部作答（包括这批取回的）比，才知道已掌握的标记还算不算数
        let ordered = results.filter { $0["type"] as? String != "mark" } + results.filter { $0["type"] as? String == "mark" }
        for r in ordered {
            guard let id = r["id"] as? String, let type = r["type"] as? String else { continue }
            switch type {
            case "choice":
                if choice(r, id: id, store: store, in: context) { summary.questions += 1; refresh.insert(scheduleKey(r)) }
            case "blank":
                if blank(r, id: id, store: store, in: context) { summary.questions += 1; refresh.insert(scheduleKey(r)) }
            case "vocab":
                if vocab(r, in: context) { summary.vocab += 1 }
            case "phrase":
                if phrase(r, in: context) { summary.phrases += 1 }
            case "passage":
                if passage(r, id: id, in: context) { summary.passages += 1 }
            case "vocab_add":
                if vocabAdd(r, in: context) { summary.vocabAdded += 1 }
            case "vocab_remove":
                if vocabRemove(r, in: context) { summary.vocabRemoved += 1 }
            case "fault":
                if fault(r, in: context) { summary.faults += 1; refresh.insert(scheduleKey(r)) }
            case "mark":
                if mark(r, in: context) { summary.marks += 1; refresh.insert(scheduleKey(r)) }
            case "skip":
                if skip(r, id: id) { summary.skips += 1 }
            case "fact":
                if fact(r, id: id, in: context) { summary.facts += 1 }
            default:
                continue
            }
        }
        for key in refresh {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { ReviewScheduler.refresh(packID: parts[0], questionID: parts[1], in: context) }
        }
        try? context.save()
        return summary
    }

    private static func scheduleKey(_ r: [String: Any]) -> String {
        "\(r["pack"] as? String ?? "")|\(r["question"] as? String ?? "")"
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    private static func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }

    // MARK: - 选择题

    private static func choice(_ r: [String: Any], id: String, store: PackStore, in context: ModelContext) -> Bool {
        guard (try? context.fetchCount(FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.phoneID == id }))) == 0,
              let packID = r["pack"] as? String, let qid = r["question"] as? String,
              let pack = store.pack(packID), let q = pack.questions[qid],
              let at = date(r["at"]), let selection = r["selection"] as? String else { return false }
        let sel = Selection.decode(selection, for: q)
        let graded = Grader.grade(q, sel)
        let duration = (r["duration"] as? NSNumber)?.doubleValue ?? 0
        let record = AttemptRecord(
            packID: packID, sectionID: pack.questionSection[qid] ?? "", questionID: qid,
            mode: AttemptMode.review.rawValue, roundNum: 0, durationSeconds: duration,
            selection: sel.encoded, selectionHistory: strings(r["selectionHistory"]),
            selectionTimes: (r["selectionTimes"] as? [NSNumber] ?? []).map(\.doubleValue),
            isCorrect: graded.isCorrect, blankResults: graded.blankResults,
            confidence: ChoiceConfidence(rawValue: r["confidence"] as? String ?? "")?.rawValue ?? ChoiceConfidence.unsure.rawValue,
            hintShown: false, weakPoints: graded.weakPoints,
            contentHash: Grader.contentHash(q), questionSnapshot: Grader.snapshot(q))
        record.createdAt = at
        record.optionOrder = strings(r["optionOrder"])
        record.phoneID = id
        // 看到答案的时间只算这次作答之前的（iPad 上可能已经有更晚的作答）
        record.sinceAnswerSeen = AttemptRecord.all(packID: packID, questionID: qid, in: context)
            .map { max($0.createdAt, $0.lastViewedAt ?? $0.createdAt) }.filter { $0 <= at }.max()
            .map { at.timeIntervalSince($0) }
        let feedback = (r["feedbackSeconds"] as? NSNumber)?.doubleValue ?? 0
        record.feedbackSeconds = feedback
        record.lastViewedAt = at.addingTimeInterval(feedback)
        record.sessionID = r["sessionID"] as? String
        record.sessionIndex = (r["sessionIndex"] as? NSNumber)?.intValue ?? 0
        // 错因：手机上没选时，答错按「知识点没掌握」（同 iPad 离开时自动提交的默认值）
        var types = strings(r["errorTypes"]).filter { ErrorType(rawValue: $0) != nil }
        if !graded.isCorrect && types.isEmpty { types = [ErrorType.notLearned.rawValue] }
        if !types.isEmpty {
            let note = (r["errorNote"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            record.errorType = types[0]
            record.errorTypes = types
            record.errorNote = note
            record.causeHistory = [CauseEntry(at: at.addingTimeInterval(feedback), type: types[0], note: note,
                                              confusedPoints: nil, types: types)]
        }
        context.insert(record)
        // iPad 复习页这道题在这之前没提交的作答作废：手机上已经做过了
        let pendingKey = PendingAnswers.choiceKey(pack: packID, mode: .review, questionID: qid)
        if let p = PendingAnswers.load(PendingAnswers.Choice.self, key: pendingKey), p.savedAt < at {
            PendingAnswers.remove(key: pendingKey)
        }
        if !graded.isCorrect { PhraseDeck.recordMiss(packID: packID, question: q, selection: record.selection, at: at, in: context) }
        return true
    }

    // MARK: - 填空题

    private static func blank(_ r: [String: Any], id: String, store: PackStore, in context: ModelContext) -> Bool {
        guard (try? context.fetchCount(FetchDescriptor<SubjectiveAttempt>(predicate: #Predicate { $0.phoneID == id }))) == 0,
              let packID = r["pack"] as? String, let qid = r["question"] as? String,
              let pack = store.pack(packID), let q = pack.subjective[qid], q.isBlank,
              let revealedAt = date(r["revealedAt"]) else { return false }
        let parts = q.effectiveParts
        let labels = parts.map(\.label)
        // 按当前题目的小问整理表单；手机上没有的小问记没做出来
        var form = SubjectiveAssessmentRules.Form()
        for (label, raw) in zip(strings(r["partLabels"]), strings(r["partResults"])) where labels.contains(label) {
            form.results[label] = PartResult(rawValue: raw)
        }
        for cause in r["partCauses"] as? [[String: Any]] ?? [] {
            guard let label = cause["label"] as? String else { continue }
            form.causes[label] = Set(strings(cause["errorTypes"]).filter { SubjectiveErrorType(rawValue: $0) != nil })
            if let note = cause["note"] as? String { form.notes[label] = note }
        }
        guard let summary = SubjectiveAssessmentRules.summarize(labels: labels, form: form) else { return false }
        let a = SubjectiveAttempt(packID: packID, sectionID: pack.questionSection[qid] ?? "", questionID: qid,
                                  mode: AttemptMode.review.rawValue)
        a.questionSnapshot = SubjectiveRecords.snapshot(q)
        a.contentHash = a.questionSnapshot.map(SubjectiveRecords.hash)
        a.createdAt = date(r["createdAt"]) ?? revealedAt
        a.phoneID = id
        a.sinceAnswerSeen = SubjectiveRecords.attempts(packID: packID, questionID: qid, in: context)
            .compactMap { x in x.revealedAt.map { max($0, x.lastViewedAt ?? $0) } }.filter { $0 <= revealedAt }.max()
            .map { revealedAt.timeIntervalSince($0) }
        a.writingSeconds = (r["writingSeconds"] as? NSNumber)?.doubleValue ?? 0
        a.feedbackSeconds = (r["feedbackSeconds"] as? NSNumber)?.doubleValue ?? 0
        a.confidenceValue = SubjectiveConfidence(rawValue: r["confidence"] as? String ?? "") ?? .unsure
        a.revealedAt = revealedAt
        a.typedAnswers = strings(r["typedAnswers"])
        a.autoMatched = strings(r["autoMatched"]).filter(labels.contains)
        a.sessionID = r["sessionID"] as? String
        a.sessionIndex = (r["sessionIndex"] as? NSNumber)?.intValue ?? 0
        let assessedAt = date(r["assessedAt"]) ?? revealedAt
        a.lastViewedAt = assessedAt
        a.partLabels = labels
        a.partResults = summary.results.map(\.rawValue)
        a.overallResult = summary.overall
        a.partCauses = summary.causes
        a.confusedPoints = summary.confusedPoints
        a.errorTypes = summary.errorTypes
        a.errorNote = summary.errorNote
        a.weakPoints = SubjectiveAssessmentRules.weakPoints(
            parts: parts.map { ($0.label, q.testedPoints(of: $0)) }, results: summary.results)
        a.assessedAt = assessedAt
        a.assessmentHistory = [SubjectiveAssessment(at: assessedAt, parts: a.partResults, result: summary.overall.rawValue,
                                                    errorTypes: a.errorTypes, note: a.errorNote, partCauses: summary.causes)]
        context.insert(a)
        return true
    }

    // MARK: - 题目有错

    /// 同 iPad 上「标记题目有错…」：faulty 为真时记下标记时间（已经标过的保留原来的时间）、问题类型和说明，为假时取消。
    /// 重复导入结果相同；复习安排在 apply 最后重算（标了有错的题不再复习）
    private static func fault(_ r: [String: Any], in context: ModelContext) -> Bool {
        guard let packID = r["pack"] as? String, let qid = r["question"] as? String, !packID.isEmpty, !qid.isEmpty,
              let on = r["faulty"] as? Bool else { return false }
        let existing = QuestionMark.fetch(packID: packID, questionID: qid, in: context)
        if !on && existing?.faulty != true { return false }
        let mark = existing ?? {
            let m = QuestionMark(packID: packID, questionID: qid)
            context.insert(m)
            return m
        }()
        let note = (r["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = FaultReason.options(variant: false)
        mark.faultyAt = on ? (mark.faultyAt ?? date(r["at"]) ?? .now) : nil
        mark.faultyNote = on && note?.isEmpty == false ? note : nil
        mark.faultyReasons = on ? allowed.filter { strings(r["reasons"]).contains($0.rawValue) }.map(\.rawValue) : []
        mark.updatedAt = .now
        return true
    }

    // MARK: - 重点、已掌握

    /// 同 iPad 上的「标为重点」「标为已掌握」：r 里是手机上这道题最后的状态。已掌握的标记还算数的保留原来的时间，
    /// 新标的用手机上标的时间（在这次作答之后，不会被它作废），取消时清掉。没有变化时返回 false；
    /// 复习安排在 apply 最后重算（已掌握会提高记忆稳定性）
    private static func mark(_ r: [String: Any], in context: ModelContext) -> Bool {
        guard let packID = r["pack"] as? String, let qid = r["question"] as? String, !packID.isEmpty, !qid.isEmpty,
              let starred = r["starred"] as? Bool, let mastered = r["mastered"] as? Bool else { return false }
        let existing = QuestionMark.fetch(packID: packID, questionID: qid, in: context)
        let wasMastered = WrongBook.isMastered(existing, in: context)
        if (existing?.starred == true) == starred && wasMastered == mastered { return false }
        let mark = existing ?? {
            let m = QuestionMark(packID: packID, questionID: qid)
            context.insert(m)
            return m
        }()
        mark.starred = starred
        if mastered != wasMastered { mark.masteredAt = mastered ? date(r["at"]) ?? .now : nil }
        mark.updatedAt = .now
        return true
    }

    // MARK: - 单词

    private static func entry(_ key: String, in context: ModelContext) -> VocabEntry? {
        try? context.fetch(FetchDescriptor<VocabEntry>(predicate: #Predicate { $0.key == key })).first
    }

    /// 同一时刻的自评已经记过的（重复导入）不再记
    private static func vocab(_ r: [String: Any], in context: ModelContext) -> Bool {
        guard let key = r["key"] as? String, let e = entry(key, in: context),
              let rating = (r["rating"] as? NSNumber).flatMap({ FSRSRating(rawValue: $0.intValue) }),
              let at = date(r["at"]) else { return false }
        return e.merge(rating, at: at, retention: ReviewScheduler.retention, createdAt: e.createdAt)
    }

    /// 说法卡的一次自评，按时间并进卡的评分历史（同背单词）；卡已经没有了就不管
    private static func phrase(_ r: [String: Any], in context: ModelContext) -> Bool {
        guard let key = r["key"] as? String,
              let card = try? context.fetch(FetchDescriptor<PhraseCard>(predicate: #Predicate { $0.key == key })).first,
              let rating = (r["rating"] as? NSNumber).flatMap({ FSRSRating(rawValue: $0.intValue) }),
              let at = date(r["at"]) else { return false }
        return card.merge(rating, at: at, retention: ReviewScheduler.retention, createdAt: card.createdAt)
    }

    /// AI 短文里划词加入的生词（同 iPad 上在 AI 短文里划词加入，packID 为 aiPassagePackID）。位置相同的已经有了就不再加；
    /// 原句按 iPad 的规则从段落里重新取。释义是手机上 AI 查的，没查到的留空，可以在生词本里重新生成
    private static func vocabAdd(_ r: [String: Any], in context: ModelContext) -> Bool {
        guard let passageID = r["passageID"] as? String, let paragraph = r["paragraph"] as? String,
              let location = (r["location"] as? NSNumber)?.intValue, let length = (r["length"] as? NSNumber)?.intValue,
              length > 0 else { return false }
        let selection = VocabSelection(aiPassageID: passageID, title: r["title"] as? String ?? "",
                                       paragraphText: paragraph, range: NSRange(location: location, length: length))
        let word = selection.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard selection.isValid, !word.isEmpty, entry(selection.key, in: context) == nil else { return false }
        let e = VocabEntry(packID: selection.packID, passageID: selection.passageID, paragraph: selection.paragraph,
                           location: location, length: length, word: word, sentence: selection.sentence)
        e.sourceTitle = selection.sourceTitle
        let text: (String) -> String? = { (r[$0] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        e.meaning = text("meaning")
        e.form = text("form")
        e.note = text("note")
        e.phonetic = text("phonetic")
        if let at = date(r["at"]) {
            e.createdAt = at
            e.dueAt = at
        }
        context.insert(e)
        return true
    }

    /// 背单词时移出生词本的词：删掉（已经删过的不算）
    private static func vocabRemove(_ r: [String: Any], in context: ModelContext) -> Bool {
        guard let key = r["key"] as? String, let e = entry(key, in: context) else { return false }
        context.delete(e)
        return true
    }

    private static func passage(_ r: [String: Any], id: String, in context: ModelContext) -> Bool {
        guard (try? context.fetchCount(FetchDescriptor<VocabPassageAttempt>(predicate: #Predicate { $0.phoneID == id }))) == 0,
              let title = r["title"] as? String, let text = r["passage"] as? String,
              let raws = r["items"] as? [[String: Any]] else { return false }
        let items = raws.compactMap { d -> VocabPassageAttempt.Item? in
            guard let n = (d["id"] as? NSNumber)?.intValue, let key = d["entryKey"] as? String else { return nil }
            return VocabPassageAttempt.Item(id: n, entryKey: key, word: d["word"] as? String ?? "",
                                            answer: d["answer"] as? String ?? "", result: d["result"] as? String,
                                            note: d["note"] as? String, rating: (d["rating"] as? NSNumber)?.intValue)
        }
        let a = VocabPassageAttempt(title: title, passage: text, items: items)
        a.createdAt = date(r["createdAt"]) ?? .now
        a.confirmedAt = date(r["confirmedAt"])
        a.phoneID = id
        if let usage = r["usage"] as? [[String: Any]], let data = try? JSONSerialization.data(withJSONObject: usage) {
            a.usage = (try? JSONDecoder().decode([LLMUsage].self, from: data)) ?? []
        }
        context.insert(a)
        if let confirmed = a.confirmedAt {
            for item in items {
                guard let raw = item.rating, let rating = FSRSRating(rawValue: raw),
                      let e = entry(item.entryKey, in: context) else { continue }
                e.merge(rating, at: confirmed, retention: ReviewScheduler.retention, createdAt: e.createdAt)
            }
        }
        return true
    }

    // MARK: - 计算测速

    /// 一轮测速记一条 FactDrill。用 iPad 的规则重新判每题（题面左边的数还原题目），不信任手机给的对错和答案。
    /// 手机上中途退出、之后接着做的一轮会用同一个 id 再交一次（答的题更多或做完了）：更新已有的那条
    private static func fact(_ r: [String: Any], id: String, in context: ModelContext) -> Bool {
        guard let raws = r["results"] as? [[String: Any]] else { return false }
        let existing = try? context.fetch(FetchDescriptor<FactDrill>(predicate: #Predicate { $0.phoneID == id })).first
        let results = raws.compactMap { d -> FactResult? in
            guard let key = d["key"] as? String, let fact = Fact(key: key),
                  let prompt = d["prompt"] as? String, let left = prompt.split(separator: " ").first.flatMap({ Int($0) }),
                  let q = ArithmeticFacts.question(fact, left: left),
                  let seconds = (d["seconds"] as? NSNumber)?.doubleValue, let at = date(d["answeredAt"]) else { return nil }
            let given = d["given"] as? String ?? ""
            return FactResult(key: key, kind: fact.kind.rawValue, prompt: q.prompt, answer: q.answer.text, given: given,
                              correct: q.isCorrect(FactAnswer.parse(given)), seconds: seconds,
                              thinkSeconds: (d["thinkSeconds"] as? NSNumber)?.doubleValue,
                              retry: d["retry"] as? Bool ?? false, answeredAt: at)
        }
        guard !results.isEmpty else { return false }
        if let existing {
            let finished = date(r["finishedAt"])
            guard results.count > existing.results.count || (existing.finishedAt == nil && finished != nil) else { return false }
            existing.results = results
            existing.finishedAt = finished
            return true
        }
        let drill = FactDrill()
        drill.createdAt = date(r["createdAt"]) ?? results[0].answeredAt
        drill.finishedAt = date(r["finishedAt"])
        drill.results = results
        drill.phoneID = id
        context.insert(drill)
        return true
    }

    // MARK: - 跳过

    private static let skipIDsKey = "phoneSync.skipIDs"

    /// 只写操作日志；最近的 id 记在 UserDefaults 里去重
    private static func skip(_ r: [String: Any], id: String) -> Bool {
        let defaults = UserDefaults.standard
        var seen = defaults.stringArray(forKey: skipIDsKey) ?? []
        guard !seen.contains(id) else { return false }
        ActivityLog.write("review_skip", ["pack": r["pack"] as? String ?? "", "question": r["question"] as? String ?? "",
                                          "device": "phone", "forever": r["forever"] as? Bool ?? false,
                                          "at": Date(timeIntervalSince1970: ((r["at"] as? NSNumber)?.doubleValue ?? 0) / 1000)
                                            .ISO8601Format()])
        seen.append(id)
        defaults.set(Array(seen.suffix(500)), forKey: skipIDsKey)
        return true
    }
}
