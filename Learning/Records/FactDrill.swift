import Foundation
import SwiftData

/// 一轮计算测速：抽出的题和每题的作答、用时（题目和判分规则见 ArithmeticFacts，流程见 FactDrillSession）。
/// 每作答一题就存一次；中途关掉的 finishedAt 为 nil，已答的题照样计入每个事实的成绩，当天再打开时接着做剩下的题
@Model
final class FactDrill {
    var createdAt: Date
    var finishedAt: Date?
    /// [FactResult]
    var resultsData: Data?
    /// 在手机复习 App 上测的、同步过来的：手机上这条结果的 id（见 PhoneSyncImport）；iPad 上测的为 nil
    var phoneID: String?
    /// 还没做的题（[FactDrill.Pending]），含答错后排到最后重出的；做完一轮清空
    var pendingData: Data?

    /// 还没做的一题：事实和题面左边的数（带余除法是被除数），用 ArithmeticFacts.question(_:left:) 还原
    nonisolated struct Pending: Codable, Sendable {
        var key: String
        var left: Int
        var retry: Bool
    }

    var pending: [Pending] {
        get { pendingData.flatMap { try? JSONDecoder().decode([Pending].self, from: $0) } ?? [] }
        set { pendingData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    init() {
        createdAt = .now
    }

    var results: [FactResult] {
        get { resultsData.flatMap { try? JSONDecoder().decode([FactResult].self, from: $0) } ?? [] }
        set { resultsData = try? JSONEncoder().encode(newValue) }
    }

    var summary: FactSummary { ArithmeticFacts.summary(results) }

    /// 每类各出几题（现在练三类，共 30 题，约两分钟；见 FactKind.practiced）
    static let perKind = 10

    /// 全部测速记录，按时间先后
    static func all(in context: ModelContext) -> [FactDrill] {
        (try? context.fetch(FetchDescriptor<FactDrill>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// 今天在这台 iPad 上没做完、还有题没做的一轮（最近的那轮）；手机上测的不算
    static func unfinishedToday(_ drills: [FactDrill]) -> FactDrill? {
        drills.last { $0.phoneID == nil && $0.finishedAt == nil && $0.pendingData != nil
            && Calendar.current.isDateInToday($0.createdAt) }
    }

    /// 今天做完过一轮
    static func doneToday(_ drills: [FactDrill]) -> Bool {
        drills.contains { $0.finishedAt.map { Calendar.current.isDateInToday($0) } == true }
    }

    /// 每个事实最近一次的成绩，抽题时答错、答得慢的多抽
    static func stats(_ drills: [FactDrill]) -> [String: FactStat] {
        ArithmeticFacts.latestStats(drills.sorted { $0.createdAt < $1.createdAt }.flatMap(\.results))
    }
}
