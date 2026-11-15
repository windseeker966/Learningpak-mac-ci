import PencilKit
import UIKit

/// 把笔迹导出成图片：按书写区切图（发给 AI 批改、讲评，存进作答记录），以及按浅色模式铺白底渲染、压缩题图
enum HandwritingExport {
    struct Images {
        /// 各书写区的截图，按书写区编号
        var areas: [Data] = []
        /// 书写区外的笔迹合成一张；没有区外笔迹时为 nil
        var outside: Data?
        /// 上面各张图（书写区在前），在界面上预览发出去的内容
        var previews: [UIImage] = []

        /// 书写区截图在前，区外那张在后
        var all: [Data] { areas + (outside.map { [$0] } ?? []) }
    }

    static let jpegQuality: CGFloat = 0.85

    /// 各书写区截一张图，书写区外的笔迹另成一张。
    /// skipEmptyAreas：不要没有笔迹的书写区（主观题批改要按书写区编号说明，保留空的区）
    static func images(_ drawing: PKDrawing, areas frames: [Int: CGRect], skipEmptyAreas: Bool = false) -> Images {
        let rects = frames.keys.sorted().compactMap { frames[$0] }
        var result = Images()
        for rect in rects where !skipEmptyAreas || drawing.strokes.contains(where: { rect.intersects($0.renderBounds) }) {
            let img = render(drawing, in: rect)
            result.previews.append(img)
            if let d = img.jpegData(compressionQuality: jpegQuality) { result.areas.append(d) }
        }
        let outsideStrokes = drawing.strokes.filter { s in !rects.contains { $0.intersects(s.renderBounds) } }
        if !outsideStrokes.isEmpty {
            let d = PKDrawing(strokes: outsideStrokes)
            let img = render(d, in: d.bounds.insetBy(dx: -20, dy: -20))
            result.previews.append(img)
            result.outside = img.jpegData(compressionQuality: jpegQuality)
        }
        return result
    }

    /// 按浅色模式渲染（深色模式下黑色墨水会被显示成白色），铺白底
    static func render(_ drawing: PKDrawing, in rect: CGRect, scale: CGFloat = 2) -> UIImage {
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
    }

    /// 资料原图压成 JPEG，长边不超过 1600 像素
    static func jpeg(contentsOf url: URL) -> Data? {
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        let longest = max(img.size.width * img.scale, img.size.height * img.scale)
        let ratio = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: img.size.width * img.scale * ratio, height: img.size.height * img.scale * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
}
