import Foundation
import SwiftData

/// 每天放一批说法卡进来（规则见 PhraseUnlock）：按排队顺序一道题一道题放，不超过每天的名额；
/// 原题里以前选错过的说法先记一次「重来」，当天排到最后背。
/// 前几天放进来的卡还有没背的，就先不放新的，免得没背的越堆越多。由根视图在算复习角标时调用，一天只放一次
@MainActor
enum PhraseIntroduction {
    private static let dateKey = "phrase.introducedDate"

    static func runIfDue(store: PackStore, in context: ModelContext, now: Date = .now) {
        let cal = Calendar.current
        if let date = UserDefaults.standard.object(forKey: dateKey) as? Date, cal.isDate(date, inSameDayAs: now) { return }
        let packs = store.packs.filter { !$0.phrases.isEmpty }
        guard !packs.isEmpty else { return }
        let cards = PhraseDeck.all(in: context)
        let today = cal.startOfDay(for: now)
        // 前几天的还没背完：先不放，也不记今天放过，背完后再进来时放
        guard !cards.contains(where: { $0.isNew && $0.createdAt < today }) else { return }

        var introducedToday = cards.filter { $0.createdAt >= today }.count
        let limit = PhraseDeck.dailyNew
        var added: [String] = []
        for pack in packs {
            let introduced = Set(cards.filter { $0.packID == pack.id }.map(\.phraseID))
            let queue = PhraseUnlock.queue(PhraseDeck.candidates(pack, in: context), introduced: introduced, now: now)
            let picks = PhraseUnlock.pick(queue, introduced: introduced, limit: limit, introducedToday: introducedToday)
            for pick in picks {
                let missed = missedBefore(pack: pack, questionID: pick.questionID, in: context)
                for id in pick.phrases {
                    let card = PhraseCard(packID: pack.id, phraseID: id, questionID: pick.questionID)
                    if missed.contains(id) {
                        card.rate(.again, at: now, retention: ReviewScheduler.retention)
                        card.seededAgain = true
                    }
                    context.insert(card)
                    added.append("\(pack.id)|\(id)")
                }
                introducedToday += pick.phrases.count
            }
        }
        try? context.save()
        UserDefaults.standard.set(now, forKey: dateKey)
        if !added.isEmpty { ActivityLog.write("phrase_introduce", ["cards": added.joined(separator: ",")]) }
    }

    /// 这道题以前的作答里选错过的选项对应的说法（看过答案后马上重做的不算）
    private static func missedBefore(pack: StudyPack, questionID: String, in context: ModelContext) -> Set<String> {
        guard let q = pack.questions[questionID], let options = q.phrases else { return [] }
        return AttemptRecord.all(packID: pack.id, questionID: questionID, in: context)
            .filter { !$0.isImmediateRedo }
            .reduce(into: Set<String>()) { out, a in
                out.formUnion(PhraseUnlock.missed(selected: Set(a.selection.map(String.init)), answer: q.answerSet,
                                                  options: options))
            }
    }
}
