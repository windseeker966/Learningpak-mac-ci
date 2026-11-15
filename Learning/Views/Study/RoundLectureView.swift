import SwiftData
import SwiftUI

/// 一轮的讲授：新知识（chunks）或巩固回顾（recap）。AI 讲解 / 原文（原书页面）/ 文字版三个视图，图片原样展示。
/// 讲解和文字版都可以划选提问，也可以在下方直接追问。讲解的生成和追问由 LectureSession 负责。
struct RoundLectureView: View {
    /// 主窗口和单独窗口共用（见 DetachableLecture）
    let session: LectureSession
    /// 「单独窗口」：到单独窗口里看讲解；nil 时不显示
    var onDetach: (() -> Void)? = nil
    /// 底部「开始做题」按钮的文字与动作
    let startLabel: String
    let onStart: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(LectureBatch.self) private var batch
    @Environment(\.renderScale) private var renderScale
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.ai
    /// 先显示标题，下一帧再渲染正文：切换轮次时菜单能立刻收起、页面立刻响应
    @State private var contentReady = false
    /// 讲解在屏幕上的每一段停留，写进操作日志
    @State private var viewSpan = ActivitySpan("lecture_view")
    @State private var onScreen = false

    /// 原文显示原书 PDF 的页面；文字版是给 AI 的整理文本，可以划选提问。包里没有 PDF 时原文就是文字版
    enum Tab: String, CaseIterable { case ai = "AI 讲解", source = "原文", text = "文字版" }

    /// 本轮全是书外补充时没有原书页面可看，「原文」显示补充的文字
    private var sourcePDF: URL? { allSupplement ? nil : pack.sourcePDFURL(for: section) }
    private var allSupplement: Bool { !chunks.isEmpty && chunks.allSatisfy(\.isSupplement) }
    private var tabs: [Tab] { sourcePDF == nil ? [.ai, .source] : Tab.allCases }

    private var pack: StudyPack { session.pack }
    private var section: SectionFile { session.section }
    private var round: Round { session.round }
    private var runner: StreamRunner { session.runner }
    private var chat: ChatSession { session.chat }
    private var cachedText: String? { session.cachedText }
    private var isRecap: Bool { session.isRecap }
    private var chunks: [Chunk] { session.chunks }
    private var lectureText: String { session.lectureText }
    private var configured: Bool { session.configured }
    /// 划选文字后的「就此提问 / 解释这段」交给追问对话处理
    private var selectionHandler: ((SelectionAction) -> Void)? { chat.handle }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !contentReady {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                content
            }
        }
        .task {
            // 让出一帧，先把标题和占位画出来
            try? await Task.sleep(for: .milliseconds(30))
            contentReady = true
        }
        .onAppear {
            // 没配置模型时直接看原文
            if !session.load(context: context, batch: batch) { tab = .source }
            onScreen = true
            updateViewSpan()
        }
        .onChange(of: scenePhase) { updateViewSpan() }
        .onChange(of: batch.version) { session.batchProgressed() }
        .onChange(of: runner.isRunning) { _, running in
            if !running { session.runnerStopped() }
        }
        .onDisappear {
            session.leave()
            onScreen = false
            updateViewSpan()
        }
    }

    private func updateViewSpan() {
        viewSpan.update(active: onScreen && scenePhase == .active,
                        ["pack": pack.id, "section": section.section.id, "round": round.num,
                         "tab": tab.rawValue, "cached": cachedText != nil])
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch tab {
            case .ai: aiView
            case .source:
                if let sourcePDF {
                    SourcePagesView(pack: pack, section: section, pdfURL: sourcePDF, chunks: chunks)
                } else {
                    sourceTextView
                }
            case .text: sourceTextView
            }

            if tab == .ai { unreferencedFiguresView }

            if configured && !runner.isRunning {
                Card {
                    Text("有疑问？继续追问").font(.headline)
                    Text("也可以在讲解或原文文字版中划选一段文字，选「就此提问」或「解释这段」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ChatThreadView(session: chat, placeholder: "比如：脱机 I/O 和联机 I/O 的区别到底在哪？", pack: pack)
                }
            }

            HStack {
                Spacer()
                Button(startLabel, systemImage: "pencil.and.list.clipboard") {
                    session.cancel()
                    onStart()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .draftTappable()
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        let title = round.displayTitle(chunkTitles: chunks.map(\.title))
        let picker = CapsuleSwitcher(items: tabs.map { t in
            .init(title: t.rawValue, selected: tab == t) { tab = t }
        })

        HStack {
            if isRecap {
                Label(title, systemImage: "arrow.triangle.2.circlepath").font(.title3.bold())
            } else {
                Text(title).font(.title3.bold())
            }
            if chunks.contains(where: \.isSupplement) { SupplementBadge(sourceLabel: pack.sourceLabel) }
            Spacer()
            if let onDetach {
                Button("单独窗口", systemImage: "rectangle.split.1x2", action: onDetach)
                    .buttonStyle(.bordered)
                    .draftTappable()
            }
            picker
        }
    }

    // MARK: - AI 讲解

    @ViewBuilder
    private var aiView: some View {
        Card {
            if !configured && cachedText == nil {
                Label("尚未配置模型。到「设置」填写 Base URL、模型名和 API Key 后即可获得 AI 讲解；现在可以先看「原文」。",
                      systemImage: "gearshape")
                    .foregroundStyle(.secondary)
            } else {
                if session.waitingForBatch {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在后台生成本节讲解，本轮完成后自动显示…").foregroundStyle(.secondary)
                    }
                } else {
                    if cachedText != nil {
                        ModelBadge(usage: session.cachedUsage, legacyModel: session.cachedModel)
                    } else {
                        StreamStatusView(runner: runner) { session.generate(useBackup: $0) }
                    }
                }
                if cachedText != nil && session.cachedVersion < Prompts.lectureVersion {
                    Label("这篇讲解是用旧版提示词生成的，点「重新生成」可以换成新的讲法。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !lectureText.isEmpty {
                    MarkdownView(text: lectureText, source: isRecap ? "你刚才的回顾" : "你刚才的讲解",
                                 onSelect: runner.isRunning ? nil : selectionHandler, pack: pack,
                                 streaming: cachedText == nil && runner.isRunning)
                }
                if !runner.isRunning && (cachedText != nil || runner.error != nil) {
                    HStack {
                        Spacer()
                        RegenerateMenu(label: "重新生成") { session.generate(useBackup: $0) }
                            .font(.callout)
                    }
                }
            }
        }
    }

    // MARK: - 原文与图

    private var sourceTextView: some View {
        Card {
            ForEach(chunks) { c in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(c.title).font(.headline)
                        Spacer()
                        Text(c.location(sourceLabel: pack.sourceLabel)).font(.caption)
                            .foregroundStyle(c.isSupplement ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Text(c.path.joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                    ForEach(c.examPoints ?? [], id: \.topic) { p in
                        Label("考点追踪：\(p.topic)（\(p.years.map(String.init).joined(separator: "、"))）",
                              systemImage: "flag.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                    SelectableText(attributed: RichText.plain(c.text, scale: renderScale),
                                   source: c.isSupplement ? "书外补充「\(c.title)」"
                                       : "\(pack.sourceLabel)原文「\(c.title)」（第 \(pageText(c.page)) 页）",
                                   onAction: configured ? selectionHandler : nil)
                    // 图紧跟在所属原文之后
                    // 原文页只放原书的图，AI 示意图只在「AI 讲解」中出现；书外补充本来就不是原书，它的示意图也放在这里
                    ForEach((c.figures ?? []).compactMap { pack.figures[$0] }.filter { !$0.isAI || c.isSupplement }) {
                        FigureView(pack: pack, figure: $0).padding(.top, 8)
                    }
                }
                if c.id != chunks.last?.id { Divider() }
            }
        }
    }

    /// AI 讲解没有用 [[图 id]] 引用到的图（如旧的缓存讲解），放在讲解之后
    @ViewBuilder
    private var unreferencedFiguresView: some View {
        let used = runner.isRunning ? [] : MarkdownParser.figureIDs(in: lectureText)
        let figs = chunks.flatMap { $0.figures ?? [] }.filter { !used.contains($0) }.compactMap { pack.figures[$0] }
        if !runner.isRunning && !figs.isEmpty {
            Card {
                Text("本轮图示").font(.headline)
                ForEach(figs) { FigureView(pack: pack, figure: $0) }
            }
        }
    }
}
