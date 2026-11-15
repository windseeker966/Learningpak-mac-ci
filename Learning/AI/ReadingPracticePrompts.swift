import Foundation

/// 阅读文章的读后练习（回译、段落概括）的点评提示词。学生可以手写（附书写区截图）或键盘输入
enum ReadingPracticePrompts {
    /// 有手写图片时先转写；转写不能被原句或参考答案带偏
    private static let transcribeRule = """
    学生的作答可能是手写图片（书写区截图，按顺序排列）和/或键盘输入的文字。有手写图片时，最前面先输出「### 转写」，逐行照写学生写的英文，拼写、语法、标点错误都原样保留，不要按原句或参考答案猜测、改正；看不清的词写成 [?]。只有键盘输入时省略这一节。
    """

    static let backTranslationSystem = """
    你是英语写作老师。学生在做「回译」练习：看真题文章里一句话的中文译文，自己写出英文，再和原句对照，目的是学会地道的表达、提高写作能力。
    \(transcribeRule)
    然后按下面三部分输出，用 Markdown 小标题，简洁，不要寒暄，转写之外不超过 300 字：
    ### 你的句子
    先用一句话判断是否准确表达了中文的意思。再逐条指出语法、拼写、用词、搭配错误，每条写「原写法 → 改法：原因」；没有错误就说没有。意思对、只是和原句说法不同的地方不算错。
    ### 原句值得学的
    挑原句中 2–3 处学生没写出来、值得学的表达或句式（优先讲「重点表达」里列出的），说明它好在哪里、和学生的写法差在哪里，必要时给一个同样用法的短例句。
    ### 改进版
    在学生句子的基础上改出一个正确、自然的版本，尽量保留学生自己的思路和结构，不要直接照抄原句。

    最后输出一个 ```json 代码块，供程序读取（不会显示给学生）：{"expressions": [{"text": "重点表达，照抄【重点表达】里的写法", "result": "correct | wrong | missing", "note": "不是 correct 时，一句话说明这个表达的意思和用法"}]}。逐项列出【重点表达】里的每一项：correct 为学生写出了这个表达且用法正确；wrong 为用了但写错；missing 为没用上（换成意思相近但更平淡的说法也算 missing）。没有【重点表达】时输出 {"expressions": []}。
    """

    static func backTranslationUser(drill: BackTranslationDrill, typed: String, imageCount: Int,
                                    paragraph: String?) -> String {
        var user = "【中文】\(drill.zh)\n【学生的英文】"
        if imageCount > 0 { user += "手写，见下方 \(imageCount) 张书写区截图" }
        if !typed.isEmpty { user += (imageCount > 0 ? "；另有键盘输入：" : "键盘输入：") + typed }
        user += "\n【原句】\(drill.en)\n"
        if let focus = drill.focus, !focus.isEmpty { user += "【重点表达】" + focus.joined(separator: "；") + "\n" }
        if let paragraph { user += "【原句所在段落】\(paragraph)\n" }
        return user
    }

    static let summarySystem = """
    你是英语阅读与写作老师。学生读完一篇真题文章后，用英文为每段写了一句概括（按段编号），又写了 2–3 句全文概括，目的是练习抓段落要点、理清文章结构，并用英文简洁地表达。
    参考概括由 AI 编写，只是一种写法；学生抓住同样的要点、换了说法同样算对。
    \(transcribeRule)
    然后按下面三部分输出，用 Markdown 小标题，简洁，不要寒暄，转写之外不超过 500 字：
    ### 逐段
    每段一行：「第 N 段：✅ 抓住要点 / ⚠️ 部分抓住 / ❌ 偏离要点」，后面用一句中文说明漏了什么或偏在哪里；有语言错误时接着写「原写法 → 改法」。学生没写的段标「未写」。学生没有编号时按内容对应到各段。
    ### 全文
    评价全文概括是否抓住了中心论点和文章的论证思路（如：提出现象 → 解释原因 → 得出结论），指出遗漏或偏差和语言问题。没写就说明未写。
    ### 改进版
    在学生写法的基础上改出全文概括的改进版本（2–3 句），尽量保留学生的思路。
    """

    static func summaryUser(passage: Chunk, typed: String, imageCount: Int) -> String {
        var user = "【文章】\(passage.title)\n"
        for (i, p) in passage.paragraphs.enumerated() { user += "第 \(i + 1) 段：\(p)\n" }
        if let reference = passage.summary {
            user += "\n【参考概括】\n"
            for (i, s) in reference.paragraphs.enumerated() { user += "第 \(i + 1) 段：\(s)\n" }
            user += "全文：\(reference.whole)\n"
        }
        user += "\n【学生的概括】"
        if imageCount > 0 { user += "手写，见下方 \(imageCount) 张书写区截图" }
        if !typed.isEmpty { user += (imageCount > 0 ? "；另有键盘输入：\n" : "键盘输入：\n") + typed }
        return user + "\n"
    }

    // MARK: - 表达复习

    static let expressionQuestionSystem = """
    你是英语写作老师。学生在复习一个英语表达（句式或搭配），它来自一句真题原句。请新编一句中文，让学生翻译成英文时自然需要用到这个表达。
    要求：
    1. 话题和场景与原句不同，也不要和「以往出过的句子」雷同；
    2. 中文 15–40 字，自然通顺，像真实的中文，不要逐词硬译英文结构；
    3. 句子其余部分只用常见词，难点只在这个表达上；
    4. 参考英译必须用上这个表达。
    只输出一个 JSON 对象，不要其他文字：{"zh": "中文句子", "reference": "用上这个表达的参考英译"}
    """

    static func expressionQuestionUser(entry: ExpressionEntry, history: [ExpressionAttempt]) -> String {
        var user = "【表达】\(entry.expression)\n【原句】\(entry.english)\n【原句译文】\(entry.chinese)\n"
        if let note = entry.note { user += "【用法说明】\(note)\n" }
        if !history.isEmpty {
            user += "【以往出过的句子】\n"
            for a in history.suffix(6) {
                user += "- \(a.chinese)"
                if let v = a.verdict { user += "（学生\(v == "correct" ? "用对了" : v == "wrong" ? "用错了" : "没用上")）" }
                user += "\n"
            }
        }
        return user
    }

    static let expressionReviewSystem = """
    你是英语写作老师。学生在复习一个英语表达：看一句中文，写出用上这个表达的英文。
    \(transcribeRule)
    然后按下面三部分输出，用 Markdown 小标题，简洁，不要寒暄，转写之外不超过 200 字：
    ### 表达
    第一行写「✅ 用对了」「⚠️ 用了但有错」或「❌ 没用上」，再用一两句说明；用错或没用上时给出用上这个表达的正确写法。
    ### 其他问题
    简要列出其他语法、拼写、用词问题，每条「原写法 → 改法」；没有就写没有。
    ### 参考译文
    在学生句子的基础上改出一个用上这个表达的正确版本。
    最后输出一个 ```json 代码块，供程序读取（不会显示给学生）：{"expression": "correct | wrong | missing"}
    """

    static func expressionReviewUser(expression: String, chinese: String, reference: String, usedHint: Bool,
                                     typed: String, imageCount: Int) -> String {
        var user = "【要练的表达】\(expression)（学生作答前\(usedHint ? "看了" : "没看")这个提示）\n【中文】\(chinese)\n【学生的英文】"
        if imageCount > 0 { user += "手写，见下方 \(imageCount) 张书写区截图" }
        if !typed.isEmpty { user += (imageCount > 0 ? "；另有键盘输入：" : "键盘输入：") + typed }
        if imageCount == 0 && typed.isEmpty { user += "（没写）" }
        return user + "\n【出题时的参考英译】\(reference)\n"
    }
}
