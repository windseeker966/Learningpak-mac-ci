import PDFKit
import SwiftUI

/// 「原文」页：按知识块的书内页码显示原书 PDF 的页面，每页只出现一次。
/// 给 AI 的仍是知识块的文本，这里只是给学生看原书。
struct SourcePagesView: View {
    let pack: StudyPack
    let section: SectionFile
    let pdfURL: URL
    let chunks: [Chunk]

    /// 书内页码 → 落在这一页的知识块
    private var pages: [(page: Int, chunks: [Chunk])] {
        var byPage: [Int: [Chunk]] = [:]
        // 书外补充不是原书内容，不显示它延伸的那几页
        for c in chunks where !c.isSupplement {
            guard let first = c.page.first else { continue }
            for p in first...(c.page.last ?? first) { byPage[p, default: []].append(c) }
        }
        return byPage.keys.sorted().map { ($0, byPage[$0]!) }
    }

    var body: some View {
        let firstPage = section.section.pdfFirstPage ?? 1
        Card {
            ForEach(chunks) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.title).font(.subheadline.bold())
                        Spacer()
                        Text(c.location(sourceLabel: pack.sourceLabel)).font(.caption)
                            .foregroundStyle(c.isSupplement ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    ForEach(c.examPoints ?? [], id: \.topic) { p in
                        Label("考点追踪：\(p.topic)（\(p.years.map(String.init).joined(separator: "、"))）",
                              systemImage: "flag.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }
            }
            ForEach(pages, id: \.page) { item in
                VStack(spacing: 6) {
                    SourcePDFPageView(url: pdfURL, index: item.page - firstPage)
                    Text("\(pack.sourceLabel)第 \(item.page) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
    }
}

/// PDF 的一页，按显示处的像素密度（含页面缩放）渲染，缩放后重新渲染
private struct SourcePDFPageView: View {
    let url: URL
    /// PDF 页下标，从 0 起
    let index: Int
    @Environment(\.renderScale) private var renderScale
    @State private var image: UIImage?
    @State private var aspect: CGFloat?
    @State private var missing = false

    /// 与 FigureView 一致的最大显示宽度
    private static let maxWidth: CGFloat = 720

    var body: some View {
        Group {
            if missing {
                Label("PDF 中没有这一页", systemImage: "doc.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                ZStack {
                    Color.white
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                // 渲染前先按页面比例占位，图出来时页面不跳
                .aspectRatio(aspect ?? 0.72, contentMode: .fit)
                .frame(maxWidth: Self.maxWidth)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
        }
        .task(id: pixelWidth) {
            let url = url, index = index, width = pixelWidth
            let result = await Task.detached(priority: .userInitiated) {
                SourcePDFRenderer.render(url: url, index: index, pixelWidth: width)
            }.value
            guard !Task.isCancelled else { return }
            if let result {
                aspect = result.aspect
                image = result.image
            } else {
                missing = true
            }
        }
    }

    /// 放大时提高分辨率；上限避免 300% 时单页图片占用过多内存
    private var pixelWidth: Int {
        Int(min(Self.maxWidth * renderScale, 3000) / 100) * 100
    }
}

nonisolated enum SourcePDFRenderer {
    struct Result: @unchecked Sendable {
        let image: UIImage
        /// 宽 / 高
        let aspect: CGFloat
    }

    /// NSCache 本身线程安全
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 300 * 1024 * 1024
        return c
    }()

    static func render(url: URL, index: Int, pixelWidth: Int) -> Result? {
        guard let doc = PDFDocument(url: url), index >= 0, let page = doc.page(at: index) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let aspect = size.width / size.height

        let key = "\(url.path)#\(index)@\(pixelWidth)" as NSString
        if let hit = cache.object(forKey: key) { return Result(image: hit, aspect: aspect) }

        let target = CGSize(width: CGFloat(pixelWidth), height: (CGFloat(pixelWidth) / aspect).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            let cg = ctx.cgContext
            // PDF 坐标原点在左下角
            cg.translateBy(x: 0, y: target.height)
            cg.scaleBy(x: target.width / size.width, y: -target.height / size.height)
            page.draw(with: .cropBox, to: cg)
        }.preparingForDisplay() ?? UIImage()
        cache.setObject(image, forKey: key, cost: pixelWidth * Int(target.height) * 4)
        return Result(image: image, aspect: aspect)
    }
}
