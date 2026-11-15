import SwiftData
import SwiftUI
import UIKit

/// 资料原图，按原样展示；点击放大
struct FigureView: View {
    let pack: StudyPack
    let figure: Figure
    @State private var zoomed = false

    var body: some View {
        VStack(spacing: 6) {
            if let image = FigureImageCache.image(at: pack.imageURL(for: figure)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 720)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .onTapGesture { zoomed = true }
                    .sheet(isPresented: $zoomed) {
                        NavigationStack {
                            ScrollView([.horizontal, .vertical]) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: max(image.size.width, 1000))
                                    .background(.white)
                            }
                            .navigationTitle(figure.caption)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { Button("完成") { zoomed = false } }
                        }
                    }
            } else {
                Label("找不到图片 \(figure.image)", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            if figure.isAI {
                Label("AI 示意图 · 非\(pack.sourceLabel) · \(figure.caption)", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(figure.caption)（\(figure.source.map { $0 + " " } ?? pack.sourceLabel)第 \(pageText(figure.page ?? [])) 页）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 图片解码缓存：图片较大，每次界面刷新都重新读文件、解码会拖慢页面
enum FigureImageCache {
    private static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 40
        return c
    }()

    static func image(at url: URL) -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let img = UIImage(contentsOfFile: url.path)?.preparingForDisplay() else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// 书外补充的标记：不是原书内容，用户同意后由 AI 编写
struct SupplementBadge: View {
    let sourceLabel: String

    var body: some View {
        Label("书外补充 · 非\(sourceLabel)内容", systemImage: "plus.square.dashed")
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
    }
}

nonisolated func pageText(_ pages: [Int]) -> String {
    pages.map(String.init).joined(separator: "–")
}

/// 生成中 / 出错 的统一展示
struct StreamStatusView: View {
    let runner: StreamRunner
    /// 出错时「重试」「换备用模型重试」的做法（参数为是否用备用模型）；nil 时把上一次请求原样再发
    var onRetry: ((Bool) -> Void)? = nil

    var body: some View {
        if let usage = runner.usage { ModelBadge(usage: usage) }
        if let error = runner.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
            if onRetry != nil || runner.canRetry {
                AIRetryButtons { useBackup in
                    if let onRetry { onRetry(useBackup) } else { runner.retry(useBackup: useBackup) }
                }
            }
        } else if runner.isRunning && !runner.hasText {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在生成…").foregroundStyle(.secondary)
            }
        }
    }
}

/// 流式生成的正文。单独成一个视图，只有它跟着 runner.text 刷新，外面的大卡片不必逐次重算
struct StreamTextView: View {
    let runner: StreamRunner
    var pack: StudyPack? = nil
    /// 显示前的处理，如去掉批改末尾的 JSON
    var transform: (String) -> String = { $0 }

    var body: some View {
        if runner.hasText {
            MarkdownView(text: transform(runner.text), pack: pack, streaming: runner.isRunning)
        }
    }
}

/// AI 生成失败或不满意时：重试，或改用备用供应商的默认模型重新生成（没启用备用供应商时只有重试）
struct AIRetryButtons: View {
    var retryLabel = "重试"
    var backupLabel = "换备用模型重试"
    var action: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(retryLabel, systemImage: "arrow.clockwise") { tap(false) }
            if LLMConfig.backup() != nil {
                Button(backupLabel, systemImage: "arrow.triangle.swap") { tap(true) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .draftTappable()
    }

    private func tap(_ useBackup: Bool) {
        ActivityLog.write("ai_retry_tap", ["label": retryLabel, "backup": useBackup])
        action(useBackup)
    }
}

/// 「重新生成」一类按钮：启用了备用供应商时，长按或点开菜单可改用备用模型
struct RegenerateMenu: View {
    var label = "重新改编"
    var action: (Bool) -> Void

    var body: some View {
        if LLMConfig.backup() != nil {
            Menu {
                Button(label, systemImage: "arrow.clockwise") { tap(false) }
                Button("用备用模型\(label)", systemImage: "arrow.triangle.swap") { tap(true) }
            } label: {
                Label(label, systemImage: "arrow.clockwise")
            } primaryAction: {
                tap(false)
            }
            .draftTappable()
        } else {
            Button(label, systemImage: "arrow.clockwise") { tap(false) }
                .draftTappable()
        }
    }

    private func tap(_ useBackup: Bool) {
        ActivityLog.write("ai_retry_tap", ["label": label, "backup": useBackup])
        action(useBackup)
    }
}

struct ModelBadge: View {
    var usage: LLMUsage?
    var legacyModel: String? = nil

    var body: some View {
        Label(usage?.label ?? legacyModel.map { "请求模型：\($0)" } ?? "模型未记录", systemImage: "cpu")
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

/// 从左到右排列，一行放不下就换行（题目导航等）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// 卡片容器
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }
}

/// 胶囊形的两三项切换。代替系统分段控件：分段控件放在缩放页面里时选中项会整块变黑，
/// 切换动画还会带着整页一起动。切换本身不做动画。
struct CapsuleSwitcher: View {
    struct Item {
        let title: String
        var systemImage: String?
        let selected: Bool
        let action: () -> Void
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    guard !item.selected else { return }
                    item.action()
                } label: {
                    HStack(spacing: 4) {
                        if let icon = item.systemImage { Image(systemName: icon) }
                        Text(item.title)
                    }
                    .font(.callout.weight(item.selected ? .semibold : .regular))
                    .foregroundStyle(item.selected ? Color.accentColor : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(item.selected ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .fixedSize()
        .transaction { $0.animation = nil }
        .draftTappable()
    }
}

