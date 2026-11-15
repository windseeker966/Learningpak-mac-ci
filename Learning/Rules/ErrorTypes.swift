import Foundation

/// 答错后由用户自评的错误类型（通用分类，不随教辅变化，可多选）
nonisolated enum ErrorType: String, CaseIterable, Sendable {
    case notLearned = "not_learned"
    case confused
    case misread
    case careless
    case guessed
    case unsure
    case other

    var label: String {
        switch self {
        case .notLearned: "知识点没掌握"
        case .confused: "两个概念混淆了"
        case .misread: "审题失误"
        case .careless: "粗心"
        case .guessed: "蒙的"
        case .unsure: "说不清"
        case .other: "其他原因"
        }
    }

    var detail: String {
        switch self {
        case .notLearned: "不知道或记不清相关知识"
        case .confused: "把相近的两个概念弄混了"
        case .misread: "没看清题目问的是什么（如「错误的是」「不属于」）"
        case .careless: "会做，但看错选项或手误"
        case .guessed: "没把握，猜的"
        case .unsure: "说不上来"
        case .other: "以上都不是，在下面写下原因"
        }
    }

    /// 可以选的类型。「蒙的」和把握程度里的「蒙的」重复，只保留在旧记录里
    static let selectable = allCases.filter { $0 != .guessed }

    /// 答对但没把握时可以选的原因
    static let unsureOptions: [ErrorType] = [.notLearned, .confused, .unsure, .other]

    /// 答错后的选项顺序：选「错误 / 不属于」的反问题把审题失误放在最前
    static func ordered(negative: Bool) -> [ErrorType] {
        negative ? [.misread] + selectable.filter { $0 != .misread } : selectable
    }

    var category: ErrorCategory {
        switch self {
        case .notLearned: .knowledge
        case .confused: .confusion
        case .misread: .reading
        case .careless: .execution
        case .guessed, .unsure: .uncertain
        case .other: .other
        }
    }
}

/// 选择题、主观题共用的错误大类。两类题各自保留贴合题型的细分错误类型，分析页按大类合并统计
nonisolated enum ErrorCategory: String, CaseIterable, Sendable {
    case knowledge
    case confusion
    case method
    case execution
    case reading
    case uncertain
    case other

    var label: String {
        switch self {
        case .knowledge: "知识没掌握"
        case .confusion: "概念混淆"
        case .method: "思路方法与步骤"
        case .execution: "计算与粗心"
        case .reading: "审题"
        case .uncertain: "没把握 / 说不清"
        case .other: "其他"
        }
    }

    /// 归入这一类的细分错误类型
    var members: String {
        let choice = ErrorType.selectable.filter { $0.category == self }.map(\.label)
        let subjective = SubjectiveErrorType.allCases.filter { $0.category == self }.map(\.label)
        return (choice.map { "选择题「\($0)」" } + subjective.map { "主观题「\($0)」" }).joined(separator: "、")
    }
}

/// 主观题的错误类型（可多选）
nonisolated enum SubjectiveErrorType: String, CaseIterable, Sendable {
    case noIdea = "no_idea"
    case misremembered
    case confused
    case method
    case calculation
    case diagram
    case misread
    case incomplete
    case other

    var label: String {
        switch self {
        case .noIdea: "没有思路"
        case .misremembered: "记错了公式或结论"
        case .confused: "两个概念混淆了"
        case .method: "方法对，步骤错漏"
        case .calculation: "计算或推导出错"
        case .diagram: "图表画错或不规范"
        case .misread: "审题错误"
        case .incomplete: "表达不完整"
        case .other: "其他原因"
        }
    }

    var detail: String {
        switch self {
        case .noIdea: "不知道从哪里下手，或不会用相关知识"
        case .misremembered: "公式、定义或结论记得不准"
        case .confused: "把相近的两个概念、算法或机制弄混了"
        case .method: "思路和方法对，但漏了或做错了某一步"
        case .calculation: "方法和步骤对，算错或推错"
        case .diagram: "状态图、表格、甘特图等画错、漏画或画法不规范"
        case .misread: "没看清题目要求，答非所问"
        case .incomplete: "结论对，但关键步骤、理由没写全"
        case .other: "以上都不是，在下面写下原因"
        }
    }

    /// 自评时可选的错误类型：填空题只看结果，没有画图和表达不完整；「记错了公式或结论」只给填空题
    static func options(blank: Bool) -> [SubjectiveErrorType] {
        blank ? allCases.filter { ![.method, .diagram, .incomplete].contains($0) } : allCases.filter { $0 != .misremembered }
    }

    var category: ErrorCategory {
        switch self {
        case .noIdea, .misremembered: .knowledge
        case .confused: .confusion
        case .method, .incomplete: .method
        case .calculation, .diagram: .execution
        case .misread: .reading
        case .other: .other
        }
    }
}
