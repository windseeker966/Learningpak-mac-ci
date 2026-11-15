import SwiftData
import SwiftUI

/// 阅读理解的上下分栏：上方文章，下方做题页，中间的分隔条可拖动，松手后吸附到三个位置之一。
/// 横屏、竖屏各记住上次停的位置。题目区收起时仍保留在视图里（高度为 0），作答状态不会丢。
struct ReadingSplitView<Bottom: View>: View {
    let pack: StudyPack
    let passage: Chunk
    /// 题目区收起时分隔条上显示的文字，如「第 2 / 5 题」
    let status: String
    @ViewBuilder var bottom: Bottom

    /// 文章区占可用高度的比例
    enum Detent: String, CaseIterable {
        /// 题目展开：看解析、讲评
        case questions
        /// 边读边做
        case standard
        /// 通读全文，题目收起成一条
        case passage

        var fraction: CGFloat {
            switch self {
            case .questions: 0.3
            case .standard: 0.6
            case .passage: 1
            }
        }
    }

    @AppStorage("reading.split.portrait") private var portraitDetent = Detent.standard
    @AppStorage("reading.split.landscape") private var landscapeDetent = Detent.standard
    /// 拖动中的位移
    @State private var drag: CGFloat = 0

    private let handleHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let detent = landscape ? landscapeDetent : portraitDetent
            let available = max(geo.size.height - handleHeight, 0)
            let passageHeight = min(max(detent.fraction * available + drag, available * 0.15), available)
            VStack(spacing: 0) {
                // 题目收起时分隔条在屏幕最底部，会被 Pencil 工具栏挡住，所以在文章标题栏也放一个展开按钮
                PassagePane(pack: pack, passage: passage,
                            expandLabel: detent == .passage ? "\(status) · 展开题目" : nil) {
                    withAnimation(.snappy) { setDetent(.standard, landscape: landscape) }
                }
                .frame(height: passageHeight)
                handle(collapsed: detent == .passage && drag == 0)
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { drag = $0.translation.height }
                            .onEnded { value in
                                // 按松手时的惯性预估落点，吸附到最近的位置
                                let target = detent.fraction * available + value.predictedEndTranslation.height
                                let next = Detent.allCases.min {
                                    abs($0.fraction * available - target) < abs($1.fraction * available - target)
                                } ?? detent
                                withAnimation(.snappy) {
                                    drag = 0
                                    setDetent(next, landscape: landscape)
                                }
                            }
                    )
                    .onTapGesture {
                        // 收起时点一下展开题目
                        guard detent == .passage else { return }
                        withAnimation(.snappy) { setDetent(.standard, landscape: landscape) }
                    }
                // 给定高度，不让 VStack 反复试探下方页面的尺寸
                bottom
                    .frame(height: available - passageHeight)
                    .clipped()
            }
        }
    }

    private func setDetent(_ detent: Detent, landscape: Bool) {
        if landscape { landscapeDetent = detent } else { portraitDetent = detent }
    }

    private func handle(collapsed: Bool) -> some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            if collapsed {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.up")
                    Text("\(status) · 点按或上拉展开题目")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Capsule().fill(.secondary.opacity(0.5)).frame(width: 44, height: 5)
            }
        }
        .frame(height: handleHeight)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .accessibilityLabel("拖动调整文章与题目的高度")
    }
}

/// 阅读文章：标题栏固定在上方（可调字号），正文按段落编号，衬线字体。
/// 划选后可以 AI 翻译、加入生词本，结果在选区旁的悬浮窗里显示；生词本里的词标黄
struct PassagePane: View {
    let pack: StudyPack
    let passage: Chunk
    /// 题目收起时标题栏上「展开题目」按钮的文字；nil 时不显示
    var expandLabel: String? = nil
    var onExpand: () -> Void = {}

    @Environment(\.modelContext) private var context
    @AppStorage("reading.fontSize") private var fontSize = 19.0
    private static let fontSizes: ClosedRange<Double> = 15...29
    @Query private var entries: [VocabEntry]

    init(pack: StudyPack, passage: Chunk, expandLabel: String? = nil, onExpand: @escaping () -> Void = {}) {
        self.pack = pack
        self.passage = passage
        self.expandLabel = expandLabel
        self.onExpand = onExpand
        let packID = pack.id, passageID = passage.id
        _entries = Query(filter: #Predicate<VocabEntry> { $0.packID == packID && $0.passageID == passageID })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize * 0.8) {
                    ForEach(Array(passage.paragraphs.enumerated()), id: \.offset) { i, paragraph in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(i + 1)")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                                .padding(.top, fontSize * 0.25)
                            PassageParagraphText(
                                text: paragraph, fontSize: fontSize,
                                highlights: entries.filter { $0.paragraph == i }.map(\.range)) { action, range in
                                    // 悬浮窗是新的 SwiftUI 根，要把数据库带过去
                                    AnyView(WordPopover(selection: VocabSelection(pack: pack, passage: passage, paragraph: i,
                                                                                   range: range),
                                                        action: action)
                                        .modelContainer(context.container))
                                }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack {
            Text(passage.title).font(.headline)
            if !entries.isEmpty {
                Label("\(entries.count) 个生词", systemImage: "character.book.closed")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer()
            if let expandLabel {
                Button(expandLabel, systemImage: "chevron.up", action: onExpand)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .padding(.trailing, 8)
            }
            Button("缩小字号", systemImage: "textformat.size.smaller") {
                fontSize = max(fontSize - 2, Self.fontSizes.lowerBound)
            }
            .disabled(fontSize <= Self.fontSizes.lowerBound)
            Button("放大字号", systemImage: "textformat.size.larger") {
                fontSize = min(fontSize + 2, Self.fontSizes.upperBound)
            }
            .disabled(fontSize >= Self.fontSizes.upperBound)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}
