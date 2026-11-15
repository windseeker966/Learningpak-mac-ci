import Foundation

/// 所有发给模型的提示词。原则：知识只能来自资料原文，AI 负责组织、比喻和讲评。
enum Prompts {
    private static func teacherRules(pack: StudyPack) -> String {
        """
        你是一位擅长把知识讲得形象、生动的老师，正在陪学生按《\(pack.title)》逐节学习。这份资料称作「\(pack.sourceLabel)」。

        必须遵守：
        1. 知识内容只能来自提供给你的原文。不补充原文以外的知识点、分类、数据或结论；原文没有说的，不要替资料说。
        2. 可以用比喻、类比、生活例子、情境等帮助理解，但要让学生清楚它们对应的是哪个概念。把原文重讲的生动、易懂是你的首要任务。
        3. 用中文回答，使用 Markdown（可以用小标题、列表、表格、加粗、引用）。原文本身是程序或伪代码时，需要对照的过程可以用代码块照原样贴出；其他内容不要使用代码块。数学公式、算式和符号用 LaTeX：行内写在 $…$ 里，单独成行的公式写成独立一段的 $$…$$；公式中的中文用 \\text{…}。
        提供给你的原文是你备课用的材料，学生并没有逐字读过。说话时直接讲知识本身，不要用「原文」「资料这里」这类说法指代它。
        """
    }

    static func chunkBlock(_ c: Chunk, _ pack: StudyPack) -> String {
        var s = "### \(c.title)\n（位置：\(c.path.joined(separator: " › "))，第 \(c.page.map(String.init).joined(separator: "–")) 页）\n"
        if c.isSupplement {
            s += "【书外补充】这一块不是\(pack.sourceLabel)原文，是学生同意后另外补充的内容（延伸上面这几页）。讲到它时要明确说明这部分是\(pack.sourceLabel)之外的补充。\n"
        }
        if let points = c.examPoints, !points.isEmpty {
            s += "【考点追踪】" + points.map { "\($0.topic)（\($0.years.map(String.init).joined(separator: "、"))）" }
                .joined(separator: "；") + "\n"
        }
        s += c.text
        for f in (c.figures ?? []).compactMap({ pack.figures[$0] }) {
            if f.isAI {
                s += "\n\n【示意图】id：\(f.id)，\(f.caption)（预处理时依据本段原文绘制，非\(pack.sourceLabel)插图）\n"
                s += "图中内容：\n\(f.transcriptText)"
            } else {
                s += "\n\n【附图】id：\(f.id)，\(f.caption)（\(f.source.map { $0 + " " } ?? pack.sourceLabel)第 \((f.page ?? []).map(String.init).joined(separator: "–")) 页）\n"
                s += "图中内容（从原图转录）：\n\(f.transcriptText)"
            }
        }
        return s
    }

    private static func chunkBlocks(_ chunks: [Chunk], _ pack: StudyPack) -> String {
        chunks.map { chunkBlock($0, pack) }.joined(separator: "\n\n")
    }

    /// 本轮之前紧挨着的那块原文：只给文字，不带图（图只在讲到它的那一轮引用）
    private static func precedingBlock(_ c: Chunk?) -> String {
        guard let c else { return "" }
        return "\n\n【上一块原文】（前面已经讲过，只用来查对本轮原文用编号或简称引用的产生式、公式、定义等，不要重讲）\n### \(c.title)\n\(c.text)"
    }

    /// 原文附有图时，教模型用占位行引用原图
    private static func figureRule(_ chunks: [Chunk], _ n: Int, mustUse: Bool) -> String {
        let ids = chunks.flatMap { $0.figures ?? [] }
        guard !ids.isEmpty else { return "" }
        let how = mustUse
            ? "讲到相关内容时，单独占一行写 [[图 图的id]]（如 [[图 \(ids[0])]]），App 会在这一行的位置显示这张图。每张图恰好引用一次，并结合图中内容讲解（例如按图的顺序串起来）。"
            : "需要时可以单独占一行写 [[图 图的id]]（如 [[图 \(ids[0])]]），App 会在这一行的位置显示这张图。"
        return "\n\(n). 原文附有图（见【附图】【示意图】）。" + how
    }

    // MARK: - 讲解提示词版本

    /// 讲解提示词版本。修改讲解/回顾提示词时加 1，旧缓存的讲解会提示「可重新生成」（9：算法类内容以例子为主线逐步讲，可贴伪代码）
    static let lectureVersion = 9

    /// 风格示范：只学写法，不照搬内容
    private static let styleExample = """
    想象有一位出手极快的大厨（CPU），炒一道菜只要 1 秒，可端菜、递菜的都是动作慢吞吞的人。大厨大部分时间都在干等——这就是**人机速度矛盾**。

    于是厨房请来一位备菜员（**外围机**），在大厨不参与的情况下，提前把菜洗好、切好，放上传送带（磁带）。大厨只和高速的传送带打交道，空等的时间一下子少了。I/O 全由备菜员完成、脱离了大厨的控制，所以叫**脱机 I/O**。

    | | 脱机 I/O | 联机 I/O |
    |---|---|---|
    | 谁来管 I/O | 外围机 | 主机直接管理 |

    💡 一句话：慢活交给助手，快手只碰快东西。
    """

    // MARK: - 新知识讲解

    static func lecture(pack: StudyPack, section: SectionFile, chunks: [Chunk],
                        learnedTitles: [String], preceding: Chunk? = nil) -> (String, [ChatTurn]) {
        let system = teacherRules(pack: pack) + """

        讲解要求：
        4. 顺着「遇到什么问题 → 怎么解决 → 又留下什么问题」来讲：先让学生看到上一阶段卡在哪里，再引出本段的做法，最后点出它的不足（原文有的话）。各部分之间要有因果衔接，不要照资料小标题逐条罗列。
        5. 讲法不限，按内容挑最合适的：比喻、生活例子、历史情境、设问引入（自问自答）、对比、画面感强的描述都可以，也可以直接讲清楚。不必每个知识点都用比喻，一个好例子胜过三个牵强的比喻。
        6. 让抽象概念先有画面再有名字：先讲它是什么样、为什么需要，再给出正式术语。术语第一次出现时加粗；加粗只给关键术语，每段不超过两处。
        7. 学生还没读过原文，你的讲解就是他第一次接触这些内容。直接把知识讲出来，不要说「原文说」「资料这里」「上面这段」「资料提到」之类，好像他已经读过一样；也不要逐句照搬原文。用自己的话讲清楚，但定义、分类名称、特征名称要准确保留（需要强调某个定义的原话时，可以说「资料中的定义是……」）。
        8. 原文用编号或简称指代的产生式、文法、公式、定义、算法步骤（如「产生式(3)(4)」「规则 2」），讲到时把它的内容完整写出来，不要只说编号；本轮原文里没有的，到【上一块原文】里查。本轮围绕一组产生式或公式展开时，开头先把它们所属的整组集中列出来（如整个文法的全部产生式，连同给出的 SELECT 集等，保留原编号），再逐个讲；不要只挑本轮提到编号的几条。
        9. 原文是算法、程序、推导或计算过程，并附有逐步执行的例子（图或表）时，以这个例子为主线讲，不要先把各个过程、规则抽象地讲一遍，再在最后概括例子：开头用一两句交代要解决什么问题，接着列出用到的文法、规则或代码；再说明表的每一列是什么、看表的规则（例如遇到什么情况做什么）；然后按步骤逐步走，每一步写明当时的状态（如当前单词、栈、集合的值）、依据哪条产生式、规则或哪几行代码、为什么这样做、做完状态变成什么，不要把几步合成一句。关键的、容易错的步骤单独点出来。这类内容不必用比喻，把每一步讲清楚就是最好的讲法。
        10. 需要对比时用表格；一个大块讲完，可以给一句口诀或「💡 一句话：……」收住（不贴切就不写）。
        11. 原文标有【考点追踪】的，用单独一行「🔥 考点：……（年份）」提醒。
        12. 最后必须有「### 本轮要点清单」：用列表逐条列出原文的全部要点（分类、特征、优缺点、条件等一个不漏），每条一句话，只写原文内容，不写比喻。清单之后用一句话提示进入练习。
        13. 不要给学生出题或留问题让他回答，也不要预告或暗示练习题的内容和答案（自问自答地引出内容可以）。
        14. 语气像一位老师在讲课，亲切、有画面感；宁可生动，不要干巴巴。
        """ + figureRule(chunks, 15, mustUse: true) + """


        【风格示范】（节选，只学写法：从问题出发、先有画面再给术语、打比方时和概念一一对应、用表格对比、一句话收住。不要照搬其中的句子；这只是讲法之一，不代表必须用比喻）
        ---
        \(styleExample)
        ---
        """
        var user = "现在学习 \(section.section.chapter) · \(section.section.id) \(section.section.title)。\n"
        if !learnedTitles.isEmpty {
            user += "本节前面已经学过：\(learnedTitles.joined(separator: "、"))。可以自然地承接，但不要重复展开。\n"
        }
        user += "\n请讲解下面的原文：\n\n" + chunkBlocks(chunks, pack) + precedingBlock(preceding)
        return (system, [ChatTurn(role: .user, text: user)])
    }

    // MARK: - 巩固轮回顾

    static func recap(pack: StudyPack, section: SectionFile, topic: String, chunks: [Chunk]) -> (String, [ChatTurn]) {
        let system = teacherRules(pack: pack) + """

        4. 这是做题前的简短回顾，不是重新讲一遍：抓住主题，做对比或梳理，优先用一张表格，控制在 400 字以内。
        5. 不要出题，不要透露任何练习题的答案。
        """ + figureRule(chunks, 6, mustUse: false)
        let user = """
        回顾主题：\(topic)
        （\(section.section.id) \(section.section.title)）

        依据的原文：

        \(chunkBlocks(chunks, pack))
        """
        return (system, [ChatTurn(role: .user, text: user)])
    }

    // MARK: - 讲解后的追问

    static func followUpSystem(pack: StudyPack, chunks: [Chunk], preceding: Chunk? = nil) -> String {
        teacherRules(pack: pack) + """

        4. 学生在听完讲解后追问。优先依据原文回答，简洁直接。
        5. 如果问题超出原文范围，先明确说「\(pack.sourceLabel)本节没有涉及」，再给出简短的一般性说明，并在该段末尾标注（\(pack.sourceLabel)未涉及）。
        6. 学生可能划选一段文字提问，消息里会写明引文的出处（你刚才的讲解 / 你前面的回答 / \(pack.sourceLabel)原文）和它所在的段落。如果出处是你自己说过的话，先对照原文核对那段是否准确；有不准确或容易误解的地方，要明确指出并更正。\(figureRule(chunks, 7, mustUse: false))

        本轮原文：

        \(chunkBlocks(chunks, pack))\(precedingBlock(preceding))
        """
    }

    // MARK: - 答后讲评

    static func review(pack: StudyPack, question q: Question, selection: Selection,
                       result: GradeResult, errorTypes: [ErrorType], errorNote: String? = nil,
                       confusedPoints: [String] = [], correctionNote: String? = nil,
                       optionOrder: OptionOrder? = nil) -> (String, [ChatTurn]) {
        let system = teacherRules(pack: pack) + """

        4. 学生刚做完一道\(q.type == .judge ? "判断题" : q.type == .multi ? "多选题" : "选择题")。请依据题目给出的答案和解析讲评：先一句话点出关键，再解释正确答案为什么对、学生的选择错在哪里（答对则说明为什么对，并点出易错点）。
        5. 学生答错时，结合所选选项、【暴露的知识点】和学生自评的错误类型与原因，推测学生可能是怎么想的，用「可能」「也许」等措辞，不要下定论；然后给出正确的理解。学生答对但写了没把握的原因时，针对这个原因把相关概念讲清楚。
        6. 知识只能来自题目、解析和给出的知识点，不得编造。标为 AI 出题时，解析也由 AI 编写，应优先对照提供的资料原文核对。
        7. 讲评简短、形象，300 字以内；之后的追问按需作答。
        8. 学生可能划选一段文字提问，消息里会写明引文的出处（你刚才的讲解 / 你前面的回答 / 资料原文）和它所在的段落。如果出处是你自己说过的话，先对照原文核对那段是否准确；有不准确或容易误解的地方，要明确指出并更正。
        9. 讲评时只采用【题目】列出的选项编号及其顺序，【学生的选择】与【正确答案】也是本次显示的编号。不要提任何其他版本的编号。
        """

        let displayed = optionOrder ?? OptionOrder(identity: q.optionKeys)
        var user = "【题目】\(q.stem)\n"
        switch q.type {
        case .single, .multi:
            for (label, key) in zip(displayed.labels, displayed.keys) {
                user += "\(label). \(q.options?[key] ?? "")\n"
            }
        case .judge:
            user += "（判断题：判断这句话正确还是错误）\n"
        case .combo:
            for k in q.statementKeys { user += "\(Roman.glyph(k)). \(q.statements?[k]?.text ?? "")\n" }
            for (label, key) in zip(displayed.labels, displayed.keys) {
                user += "\(label). " + (q.comboOptions?[key] ?? []).map(Roman.glyph).joined(separator: "、") + "\n"
            }
        case .multiBlank:
            for k in q.optionKeys { user += "\(k). \(q.sharedOptions?[k] ?? "")\n" }
        }

        let selectedKeys: [String]
        switch selection {
        case .option(let value):
            selectedKeys = q.type == .multi ? value.map(String.init) : [value]
        case .blanks:
            selectedKeys = []
        }
        let picked: String
        if q.type == .multi {
            picked = displayed.labels(of: selectedKeys).joined(separator: "、")
        } else if q.type == .multiBlank {
            picked = selection.encoded.replacingOccurrences(of: ",", with: "、")
        } else {
            picked = selectedKeys.first.map { displayed.label(of: $0) } ?? ""
        }
        let correctAnswer: String
        switch q.type {
        case .multi:
            correctAnswer = displayed.labels(of: q.answerSet).joined(separator: "、")
        case .single, .combo:
            correctAnswer = displayed.label(of: q.answer ?? "")
        default:
            correctAnswer = q.answerText
        }
        user += "\n【学生的选择】\(picked.isEmpty ? "（没选）" : picked)"
        user += result.isCorrect ? "（正确）\n" : "（错误）\n"
        if displayed.isShuffled {
            let chosenTexts = selectedKeys.map { key -> String in
                if q.type == .combo {
                    return (q.comboOptions?[key] ?? []).map(Roman.glyph).joined(separator: "、")
                }
                return q.options?[key] ?? ""
            }.filter { !$0.isEmpty }
            if !chosenTexts.isEmpty {
                user += "【学生所选内容】" + chosenTexts.joined(separator: "；") + "\n"
            }
        }
        user += "【正确答案】\(correctAnswer)" + (q.aiWritten == .answer ? "（\(pack.sourceLabel)没有答案，由 AI 补写）" : "") + "\n"
        if displayed.isShuffled {
            user += "【讲评依据】所有选项编号均以本次题目中的排列为准。若解析中的个别字母仍与本次排列不一致，必须根据选项内容和正确答案核对，不得沿用不一致的编号，也不要提及其他排列。\n"
        }
        let explanation = displayed.relabelOptionReferences(in: q.explanation)
        if q.aiAuthored {
            user += "【解析】（这道题是 AI 依据原文出的，解析也是 AI 编写，讲评时如发现与原文不符，以原文为准并指出）\(explanation)\n"
        } else if q.aiWritten != nil {
            user += "【解析】（\(pack.sourceLabel)没有解析，由 AI 编写，讲评时如发现有误，指出并纠正）\(explanation)\n"
        } else {
            user += "【\(pack.sourceLabel)解析】\(explanation)\n"
        }

        if let passage = q.passage.flatMap({ pack.chunks[$0] }) {
            user += "【阅读文章】\n" + chunkBlocks([passage], pack) + "\n"
        }
        if q.aiAuthored {
            let basis = q.requires.filter { $0 != q.passage }.compactMap { pack.chunks[$0] }
            if !basis.isEmpty { user += "【出题依据的资料原文】\n" + chunkBlocks(basis, pack) + "\n" }
        }

        let tested = q.testedPoints.map(pack.pointTitle)
        if !tested.isEmpty { user += "【本题考查的知识点】" + tested.joined(separator: "、") + "\n" }

        if !result.isCorrect {
            if !result.misjudgedStatements.isEmpty {
                user += "【学生判断错的陈述】" + result.misjudgedStatements.map(Roman.glyph).joined(separator: "、") + "\n"
            }
            if !result.weakPoints.isEmpty {
                user += "【暴露的知识点】（根据所选选项推算）" + result.weakPoints.map(pack.pointTitle).joined(separator: "、") + "\n"
            }
            if !errorTypes.isEmpty {
                user += "【学生自评的错误类型】" + errorTypes.map(\.label).joined(separator: "、") + "\n"
            }
            if let errorNote, !errorNote.isEmpty {
                user += "【学生写的错误原因】\(errorNote)\n"
            }
        } else {
            // 答对但没把握时填的原因
            if !errorTypes.isEmpty {
                user += "【学生答对了但没把握，自评原因】" + errorTypes.map(\.label).joined(separator: "、") + "\n"
            }
            if let errorNote, !errorNote.isEmpty {
                user += "【学生写的没把握的原因】\(errorNote)\n"
            }
        }
        if errorTypes.contains(.confused) && !confusedPoints.isEmpty {
            user += "【学生认为弄混的知识点】" + confusedPoints.map(pack.pointTitle).joined(separator: "、") + "\n"
        }
        if let correctionNote, !correctionNote.isEmpty {
            user += "【学生写的订正笔记，讲评时帮他核对是否准确】\(correctionNote)\n"
        }
        return (system, [ChatTurn(role: .user, text: user)])
    }

    /// 主观题的解题过程：原书只有答案时由 AI 编写，提醒模型可能有误
    static func subjectiveExplanation(_ q: SubjectiveQuestion, pack: StudyPack) -> String {
        guard let e = q.explanation else { return "" }
        return q.aiWritten != nil
            ? "【解析】（\(q.aiWritten == .answer ? "原书没有答案，答案和解析都" : "\(pack.sourceLabel)只有答案，解析")由 AI 编写，发现有误时指出并纠正）\n\(e)\n"
            : "【\(pack.sourceLabel)解析】\n\(e)\n"
    }

    // MARK: - 综合题讲评与追问

    static func subjectiveReview(pack: StudyPack, question q: SubjectiveQuestion, attempt: any SubjectiveAttemptRecord,
                                 handwritingCount: Int, images: [Data]) -> (String, [ChatTurn]) {
        let system = teacherRules(pack: pack) + """

        4. 学生已经看过\(q.isBlank ? "填空题" : "综合应用题")的参考答案，现在需要解题讲评和后续追问。先指出本题的切入点，再串起关键步骤，说明如何检查结果；初次讲评约 400 字，追问按需展开。
        5. 依据给出的题面、参考答案、得分点和资料原文讲解。按小问自评和错误原因重点解释薄弱步骤；学生未自评时不替他判断正误。
        6. 附图中前面的学生手写仅用于了解他的实际作答；不要把参考答案当作学生写过的内容。看不清就明确说看不清。已有 AI 批改是辅助信息，发现与参考答案不符时应指出并更正。
        7. 没有学生作答或批改时，仍可讲解参考答案，但不得虚构他的错误。不要把一般讲评当作正式批改或自动改变学生自评。
        8. 学生划选文字提问时，先核对引文出处；若引文来自你自己的回答，发现不准确之处要明确更正。
        """
        var user = "【题目】\n" + (q.stem ?? "题面见附图") + "\n"
        user += "【参考答案】\n" + (q.answer ?? "参考答案见附图或各小问") + "\n"
        user += subjectiveExplanation(q, pack: pack)
        for (i, part) in q.effectiveParts.enumerated() {
            user += "【\(q.isBlank ? "空" : "小问") \(part.label)】"
            if let answer = part.answer { user += "参考答案：" + answer + "\n" }
            if let accept = part.accept { user += "可接受的答案：" + accept.joined(separator: "、") + "\n" }
            if q.typed {
                let empty = attempt.pastedBeforeReveal.isEmpty ? "（没填）" : "（键盘没填，可能写在附图里）"
                user += "学生填写：" + (i < attempt.typedAnswers.count && !BlankMatcher.isEmpty(attempt.typedAnswers[i]) ? attempt.typedAnswers[i] : empty) + "\n"
            }
            if let points = part.points { user += "得分点：" + points.joined(separator: "；") + "\n" }
            user += "学生自评：" + (attempt.result(of: part.label)?.label ?? "尚未自评") + "\n"
        }
        user += "【整题自评】" + (attempt.resultValue?.label ?? "尚未自评") + "\n"
        if let confidence = attempt.confidenceValue {
            user += "【看答案前的把握程度】" + confidence.label + "\n"
        }
        let causes = attempt.causeLines(pack.pointTitle)
        if !causes.isEmpty { user += "【自评的错误类型与原因】" + causes.joined(separator: "；") + "\n" }
        if let note = attempt.correctionNote, !note.isEmpty {
            user += "【学生写的订正笔记，讲评时帮他核对是否准确】" + note + "\n"
        }
        if let grading = attempt.gradings.last(where: { $0.completed }) {
            user += "【已有 AI 批改，需核对】\n" + GradingVerdict.displayText(grading.text) + "\n"
        }
        let basis = (q.requires ?? []).compactMap { pack.chunks[$0] }
        if !basis.isEmpty { user += "【出题依据的资料原文】\n" + chunkBlocks(basis, pack) + "\n" }
        if !q.testedPoints.isEmpty { user += "【考查知识点】" + q.testedPoints.map(pack.pointTitle).joined(separator: "、") + "\n" }
        user += "【附图顺序】前 \(handwritingCount) 张是看答案前的学生手写，之后"
        user += q.questionImage == nil ? "" : "是题面图，最后"
        user += "是参考答案图。没有手写图时不要猜测学生作答。\n请讲评这道\(q.kindLabel)。"
        return (system, [ChatTurn(role: .user, text: user, images: images)])
    }

    // MARK: - 主观题批改

    /// 学生手写作答的批改。images 依次是：各书写区的手写图片（以及书写区外的笔迹），之后是参考答案的原图。
    /// 输出先给最终批改结果，再如实转写手写内容并展开对照分析。
    /// excludedStrokes：看答案后补写、没有发给 AI 的笔画数
    static func subjectiveGrading(pack: StudyPack, question q: SubjectiveQuestion, areaCount: Int,
                                  hasOutsideInk: Bool, pastedCount: Int = 0, answerImageCount: Int,
                                  questionImageCount: Int, excludedStrokes: Int = 0,
                                  excludedPasted: Int = 0) -> (String, String) {
        let labels = q.effectiveParts.map(\.label)
        // 转写按实际发出的图片分段：只贴了图片时没有书写区，不能让 AI 按书写区编号
        var sources: [String] = []
        if areaCount > 0 { sources.append("书写区 1、书写区 2……（共 \(areaCount) 个书写区）") }
        if hasOutsideInk { sources.append("书写区以外的笔迹") }
        if pastedCount > 0 { sources.append("贴上的图片 1、图片 2……（共 \(pastedCount) 张）") }
        let seen = "按学生作答的来源逐个写出转写结果：" + sources.joined(separator: "，然后是") + "；某一项空白就写「空白」。"
            + (areaCount == 0 ? "这次没有书写区，不要提到书写区。" : "")
        let system = """
        你是一位认真、严谨的阅卷老师，正在批改学生在 iPad 上手写的主观题答案。教材：《\(pack.title)》。

        必须遵守：
        1. 先仔细核对手写内容和参考答案，但输出时必须先给最终批改结果，再写转写和分析。不要把你推测学生想写的内容当成学生写了的内容。
        2. 转写时尽量逐字、逐式；图表（转换图、甘特图、表格等）要写出你看到的结点、边、标记、数值。看不清或无法确定的地方写「〔看不清：……〕」并说明你猜测的几种可能，不要擅自补全。
        3. 图片里的划掉、涂抹、明显写错又改的地方，照实说明；涂抹掉的内容不算作答。
        4. 批改以参考答案为准，知识只能来自题目和参考答案；参考答案之外的等价写法如果正确，也要认可并说明理由。
        5. 用中文、Markdown 输出，公式用 LaTeX（行内 $…$，独立 $$…$$）。
        6. 按以下结构输出，标题照写：
        ## 最终批改结果
        第一句明确给出：正确 / 基本正确 / 部分正确 / 错误 / 未作答 / 无法判断。然后简要说明最需要改正的一点；多问的题目逐问给出结果。若关键笔迹看不清，明确说无法判断，不要给出假定学生写法的结论。
        ## 我看到的内容
        \(seen)
        ## 不确定的地方
        列出所有看不清、可能误读的地方；没有就写「无」。
        ## 对照参考答案
        逐问、逐步比较，指出正确、遗漏、错误之处；给了得分点的，逐个说明是否写出。
        ## 结构化结果
        最后输出一个 ```json 代码块，供程序读取：{"parts": [{"label": "小问编号", "result": "correct | partial | wrong | blank | unclear", "missing": ["没写出或写错的得分点"], "note": "一句话说明"}]}。
        parts 按顺序覆盖这些小问，label 照写：\(labels.joined(separator: "、"))。result 含义：correct 对，partial 部分对，wrong 错，blank 没作答，unclear 笔迹看不清无法判断。
        """ + (q.isBlank ? """

        7. 这是填空题，每个小问是一个空。只看每空最后填的结果是否与参考答案等价，不要求写出过程；草稿演算不算作答，也不因过程扣分。result 只用 correct、wrong、blank、unclear，不用 partial。
        """ : "")
        var user = "【题目】\n"
        if let stem = q.stem { user += stem + "\n" }
        if questionImageCount > 0 { user += "（题目还有 \(questionImageCount) 张原题图片，见下方说明）\n" }
        user += "\n【参考答案】" + (q.aiAuthored == true || q.aiWritten == .answer ? "（AI 编写，仅供参考）" : "（\(pack.sourceLabel)原答案）") + "\n"
        if let answer = q.answer { user += answer + "\n" }
        if answerImageCount > 0 { user += "（参考答案还有 \(answerImageCount) 张原图，见下方说明）\n" }
        user += subjectiveExplanation(q, pack: pack)
        if let parts = q.parts, !parts.isEmpty {
            user += "\n【小问与得分点】\n"
            for p in parts {
                user += "\(p.label)"
                if let a = p.answer { user += " 参考答案：\(a)" }
                if let acc = p.accept { user += " 可接受的答案：" + acc.joined(separator: "、") }
                if let pts = p.points, !pts.isEmpty { user += " 得分点：" + pts.joined(separator: "；") }
                user += "\n"
            }
        }
        if excludedStrokes > 0 {
            user += "\n（学生看过参考答案后又补写了 \(excludedStrokes) 笔，这些笔迹没有包含在图片里，只批改看答案前写的内容。）\n"
        }
        if excludedPasted > 0 {
            user += "\n（学生看过参考答案后又补贴了 \(excludedPasted) 张图片，没有附上，只批改看答案前的内容。）\n"
        }
        user += "\n【图片说明】随消息附上的图片按顺序是：\n"
        var n = 1
        for i in 0..<areaCount {
            user += "第 \(n) 张：学生手写，书写区 \(i + 1)\n"; n += 1
        }
        if hasOutsideInk { user += "第 \(n) 张：学生写在书写区以外的笔迹（可能是草稿，也可能是答案的一部分）\n"; n += 1 }
        for i in 0..<pastedCount {
            user += "第 \(n) 张：学生在另一个笔记 App 里手写后截取的图片 \(i + 1)（可能带有笔记本的格线或其他页面内容，只批改与本题有关的部分）\n"; n += 1
        }
        for i in 0..<questionImageCount { user += "第 \(n) 张：原题图片 \(i + 1)\n"; n += 1 }
        for i in 0..<answerImageCount { user += "第 \(n) 张：参考答案原图 \(i + 1)\n"; n += 1 }
        user += "\n请先输出【最终批改结果】，再按要求写出手写转写、不确定之处和对照分析，最后输出结构化结果。"
        return (system, user)
    }

    // MARK: - 键盘输入的填空题

    /// 判断学生填的内容和参考答案是否等价。只发给 AI 自动比对没对上的空，结论用来预选自评。
    /// pastedCount：看答案前贴的图片张数（随请求附上），没用键盘填的空可能写在图片里
    static func blankTextGrading(pack: StudyPack, question q: SubjectiveQuestion, typed: [String], matched: Set<String>,
                                 pastedCount: Int = 0, excludedPasted: Int = 0) -> (String, String) {
        let parts = q.effectiveParts
        let imageRule = pastedCount == 0 ? "" : """

        5. 学生还附上了手写后截取的图片。键盘没填的空，先在图片里找这个空的答案，按图片内容判断；图片里也没有才算没填。图片里看不清就给 unclear。键盘填了的空以键盘内容为准。
        """
        let system = """
        你是一位认真、严谨的阅卷老师，正在批改学生用键盘填写的填空题。教材：《\(pack.title)》。

        必须遵守：
        1. 逐空判断学生填的内容与参考答案是否等价。同义词、等价的数学表达式、数值相等的不同写法算对；概念不同、少了关键限定、数值不等的算错。带单位的数值，单位必须正确或题目已给出单位。拿不准时给 unclear 并说明原因。
        2. 只依据题目和参考答案，不补充原文以外的知识。
        3. 用中文、Markdown 输出，公式用 LaTeX（行内 $…$）。
        4. 按以下结构输出，标题照写：
        ## 最终批改结果
        逐空一行：编号、学生填的内容、结论（对 / 错 / 没填 / 无法判断）和一句话理由。
        ## 结构化结果
        最后输出一个 ```json 代码块，供程序读取：{"parts": [{"label": "空的编号", "result": "correct | wrong | blank | unclear", "note": "一句话说明"}]}。
        parts 只覆盖需要你判断的空，label 照写。
        """ + imageRule
        var user = "【题目】\n" + (q.stem ?? "（题面见原题图，未附上）") + "\n"
        if let answer = q.answer { user += "\n【参考答案与解析】\n" + answer + "\n" }
        user += "\n【需要判断的空】\n"
        for (i, p) in parts.enumerated() where !matched.contains(p.label) {
            let input = i < typed.count ? typed[i] : ""
            let empty = pastedCount > 0 ? "（键盘没填，看附图）" : "（没填）"
            user += "\(p.label) 学生填写：\(BlankMatcher.isEmpty(input) ? empty : input)；"
            user += "参考答案：" + ([p.answer] + (p.accept ?? []).map { Optional($0) }).compactMap { $0 }.joined(separator: " / ") + "\n"
        }
        if !matched.isEmpty {
            user += "\n（其余的空 \(parts.map(\.label).filter(matched.contains).joined(separator: "、")) 已与参考答案逐字一致，不用判断。）\n"
        }
        if pastedCount > 0 {
            user += "\n【附图】共 \(pastedCount) 张，都是学生在另一个笔记 App 里手写后截取的图片（可能带有格线或其他页面内容，只看与本题有关的部分）。\n"
            if excludedPasted > 0 { user += "（看答案后补贴的 \(excludedPasted) 张不算作答，没有附上。）\n" }
        }
        return (system, user)
    }

    // MARK: - 连接测试

    static let connectionTest = ("你是一个连接测试助手。", [ChatTurn(role: .user, text: "请只回复四个字：连接成功")])
}
