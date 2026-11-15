import Foundation

/// 被划选的一段文字及其出处
nonisolated struct SelectionQuote: Equatable, Sendable {
    /// 选中的文字
    let text: String
    /// 出处，如「你刚才的讲解」「原书原文「脱机I/O方式」（第 7 页）」
    let source: String
    /// 所在的整段文字，帮助 AI 定位
    let paragraph: String
}

/// 选中文字后的菜单动作
nonisolated enum SelectionAction {
    /// 引用选中内容，由用户接着写问题
    case ask(SelectionQuote)
    /// 直接请 AI 解释选中内容
    case explain(SelectionQuote)
}

