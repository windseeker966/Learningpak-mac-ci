import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 在别的 App（如 GoodNotes）里写好、贴进来的一张作答图片
nonisolated struct PastedImage: Codable, Identifiable, Sendable {
    var id = UUID()
    /// 贴入时间：看答案前贴的才算作答，交给 AI 批改
    var at = Date.now
    /// JPEG
    var data: Data

    /// 统一成白底 JPEG，长边不超过 2000 像素（透明背景的截图在深色模式下会看不清）
    static func normalized(_ raw: Data) -> Data? {
        guard let img = UIImage(data: raw) else { return nil }
        let longest = max(img.size.width * img.scale, img.size.height * img.scale)
        let ratio = min(1, 2000 / max(longest, 1))
        let size = CGSize(width: (img.size.width * img.scale * ratio).rounded(),
                          height: (img.size.height * img.scale * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            img.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.85)
    }
}

/// 主观题的「贴图片作答」：在 GoodNotes 等 App 里写好，截图或套索拷贝后粘贴、拖入，或从相册选。
/// 看答案后补贴的单独标出，不交给 AI 批改；看答案前贴的看答案后不能再删。
struct PastedAnswerCard: View {
    let images: [PastedImage]
    let revealedAt: Date?
    var onAdd: ([Data]) -> Void
    var onDelete: (UUID) -> Void

    @State private var picked: [PhotosPickerItem] = []
    @State private var zoomed: PastedImage?
    @State private var dropTargeted = false
    @State private var loadError: String?

    private func afterReveal(_ img: PastedImage) -> Bool { revealedAt.map { img.at >= $0 } ?? false }

    var body: some View {
        Card {
            HStack {
                Label("贴图片作答", systemImage: "photo.on.rectangle").font(.headline)
                Spacer()
                PasteButton(supportedContentTypes: [.image]) { providers in load(providers) }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                PhotosPicker(selection: $picked, maxSelectionCount: 6, matching: .images) {
                    Label("从相册选", systemImage: "photo")
                }
                .buttonStyle(.bordered)
            }
            Text(revealedAt == nil
                 ? "在 GoodNotes 里写好后截图或用套索拷贝，粘贴或拖到这里；可以贴多张。看答案前贴的会交给 AI 批改。"
                 : "看答案后补贴的图片单独标出，不交给 AI 批改。")
                .font(.caption).foregroundStyle(.secondary)
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if images.isEmpty {
                Text("还没有图片。也可以把图片直接拖进这个框。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(Array(images.enumerated()), id: \.element.id) { i, img in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("图片 \(i + 1)").font(.subheadline.bold())
                            if afterReveal(img) {
                                Text("看答案后补贴").font(.caption.bold())
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            if revealedAt == nil || afterReveal(img) {
                                Button("删除", systemImage: "trash", role: .destructive) { onDelete(img.id) }
                                    .labelStyle(.iconOnly)
                            }
                        }
                        if let ui = UIImage(data: img.data) {
                            Image(uiImage: ui).resizable().scaledToFit()
                                .frame(maxHeight: 420)
                                .opacity(afterReveal(img) ? 0.6 : 1)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                .onTapGesture { zoomed = img }
                        }
                    }
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: 3)
            }
        }
        .onDrop(of: [.image], isTargeted: $dropTargeted) { providers in
            load(providers)
            return true
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var datas: [Data] = []
                for item in items {
                    if let raw = try? await item.loadTransferable(type: Data.self),
                       let d = PastedImage.normalized(raw) { datas.append(d) }
                }
                finish(datas, expected: items.count)
            }
        }
        .sheet(item: $zoomed) { img in
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    if let ui = UIImage(data: img.data) { Image(uiImage: ui) }
                }
                .toolbar { Button("完成") { zoomed = nil } }
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        Task {
            var datas: [Data] = []
            for p in providers {
                if let raw = await Self.imageData(p), let d = PastedImage.normalized(raw) { datas.append(d) }
            }
            finish(datas, expected: providers.count)
        }
    }

    private func finish(_ datas: [Data], expected: Int) {
        loadError = datas.count < expected ? "有 \(expected - datas.count) 张没能读成图片。" : nil
        if !datas.isEmpty { onAdd(datas) }
    }

    private static func imageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                cont.resume(returning: data)
            }
        }
    }
}
