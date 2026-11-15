import SwiftData
import SwiftUI

/// 题目下方的空白书写区。只是页面上的留白，笔迹写在整页的草稿画布上；
/// 书写区数量存在 SubjectiveProgress（主观题、选择题共用），书写区在页面上的位置记进详细笔迹记录，
/// 用来判断每一笔落在哪个书写区。
struct WritingAreaList: View {
    let count: Int
    /// 详细笔迹记录的上下文；nil 时不记录书写区位置（复习页、AI 改编页）
    let ctx: SubjectiveRecordContext?
    /// 各书写区在页面坐标中的位置（主观题 AI 批改要按它截取笔迹）
    @Binding var frames: [Int: CGRect]
    /// 传入时把书写区位置登记到 WritingAreaFrames（选择题按它收集每次作答的笔迹）
    var pageKey: String? = nil
    @State private var logTask: Task<Void, Never>?

    static let areaHeight: CGFloat = 520

    var body: some View {
        ForEach(0..<count, id: \.self) { i in
            Color.clear
                .frame(height: Self.areaHeight)
                .frame(maxWidth: .infinity)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    .foregroundStyle(.tertiary))
                .overlay(alignment: .topLeading) {
                    Text("书写区 \(i + 1)").font(.caption).foregroundStyle(.tertiary).padding(10)
                }
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(draftPageSpace)) } action: { frame in
                    frames[i] = frame
                    if let pageKey { WritingAreaFrames.frames[pageKey, default: [:]][i] = frame }
                    scheduleLog()
                }
        }
        .onChange(of: count) { _, new in
            frames = frames.filter { $0.key < new }
            if let pageKey { WritingAreaFrames.frames[pageKey] = frames }
        }
        .onDisappear { logTask?.cancel() }
    }

    /// 书写区位置变化后稳定 1 秒再记一次
    private func scheduleLog() {
        logTask?.cancel()
        guard let ctx = self.ctx else { return }
        logTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let areas = frames.keys.sorted().compactMap { frames[$0] }
                .map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
            SubjectiveInkLog.write("writing_areas", ctx, SimplePayload(page_count: areas.count, areas: areas))
        }
    }

    /// 删除第 i 个书写区：画布先移走它上面的笔迹（存档）并把下方笔迹上移，调用方随后减少书写区数量
    static func deleteArea(_ i: Int, frames: [Int: CGRect], draftKey: String) -> Bool {
        guard let rect = frames[i] else { return false }
        // 书写区之间的间距是 20
        DraftAnchors.deleteArea(draftKey, rect: rect, shift: rect.height + 20)
        return true
    }

    static func addArea(_ progress: SubjectiveProgress, ctx: SubjectiveRecordContext, in context: ModelContext) {
        progress.pageCount += 1
        progress.updatedAt = .now
        try? context.save()
        SubjectiveInkLog.write("area_added", ctx, SimplePayload(page_count: progress.pageCount))
    }
}

/// 各页书写区最近一次报告的位置（页面坐标），按草稿键。作答卡片和书写区是兄弟视图，从这里取位置
@MainActor
enum WritingAreaFrames {
    static var frames: [String: [Int: CGRect]] = [:]
}

/// 「删除书写区」菜单：选一个书写区删掉，它上面的笔迹一起从页面上移走（存档，不删记录）
struct DeleteAreaMenu: View {
    let count: Int
    let onDelete: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(0..<count, id: \.self) { i in
                Button("删除书写区 \(i + 1)", systemImage: "trash", role: .destructive) { onDelete(i) }
            }
        } label: {
            Label("删除书写区", systemImage: "minus.rectangle")
        }
        .disabled(count == 0)
    }
}

/// 选择题书写区的配置，交给 QuestionCard 在题目（和解析）下方显示
struct WritingSpec {
    let sectionID: String
    var draftKey: String? = nil
    var storage: ChoiceWritingSection.Storage = .study
    var anchorName = DraftAnchors.writing
}

/// 选择题下方的书写区：默认没有，点「添加书写区」再加
struct ChoiceWritingSection: View {
    /// 书写区数量和位置记在哪里
    enum Storage {
        /// 学习页：数量存数据库，位置写进详细笔迹记录
        case study
        /// 复习页：数量存数据库（与学习页共用），不写详细笔迹记录
        case review
        /// AI 改编：只在内存里，不写数据库
        case memory
    }

    let pack: StudyPack
    let sectionID: String
    let questionID: String
    /// 这一页的草稿键，笔迹跟随书写区移动时用
    var draftKey: String? = nil
    var storage: Storage = .study
    /// 锚点名（同一页有多个书写部分时区分，见 DraftAnchors）
    var anchorName = DraftAnchors.writing
    /// 接在「删除书写区」右边的按钮（重做、下一题等），和书写区按钮排成一行
    var accessory: AnyView? = nil
    /// .memory 时一开始的书写区数量
    var initialMemoryAreas = 0
    /// 第一次打开这道题时的书写区数量（学习页、复习页）；默认没有，点「添加书写区」再加
    var initialAreas = 0
    /// 传入时书写区位置写到这里（AI 改编题批改要按它截取笔迹）
    var areaFrames: Binding<[Int: CGRect]>? = nil

    @Environment(\.modelContext) private var context
    @State private var progress: SubjectiveProgress?
    @State private var memoryCount = 0
    @State private var frames: [Int: CGRect] = [:]

    private var ctx: SubjectiveRecordContext {
        SubjectiveRecordContext(packID: pack.id, sectionID: sectionID, questionID: questionID)
    }

    private var count: Int { storage == .memory ? memoryCount : progress?.pageCount ?? 0 }

    private var pageKey: String { draftKey ?? DraftKey.question(pack: pack.id, questionID: questionID) }

    private func deleteArea(_ i: Int) {
        guard WritingAreaList.deleteArea(i, frames: areaFrames?.wrappedValue ?? frames, draftKey: pageKey) else { return }
        if storage == .memory {
            memoryCount = max(memoryCount - 1, 0)
        } else if let progress {
            progress.pageCount = max(progress.pageCount - 1, 0)
            progress.updatedAt = .now
            try? context.save()
            if storage == .study {
                SubjectiveInkLog.write("area_deleted", ctx, SimplePayload(page_count: progress.pageCount, note: "area \(i + 1)"))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WritingAreaList(count: count, ctx: storage == .study ? ctx : nil, frames: areaFrames ?? $frames,
                            pageKey: storage == .memory ? nil : pageKey)
            HStack(spacing: 12) {
                Button("添加书写区", systemImage: "plus.rectangle.on.rectangle") {
                    if storage == .memory {
                        memoryCount += 1
                    } else if let progress {
                        if storage == .study {
                            WritingAreaList.addArea(progress, ctx: ctx, in: context)
                        } else {
                            progress.pageCount += 1
                            progress.updatedAt = .now
                            try? context.save()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .draftTappable()
                DeleteAreaMenu(count: count) { deleteArea($0) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .draftTappable()
                if let accessory { accessory }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 提交后题目下方展开解析，书写区被推下去，笔迹跟着走
        .draftInkAnchor(pageKey, name: anchorName)
        .onAppear {
            guard storage != .memory else {
                if memoryCount == 0 { memoryCount = initialMemoryAreas }
                return
            }
            progress = SubjectiveProgress.fetchOrCreate(packID: pack.id, sectionID: sectionID,
                                                        questionID: questionID, initialPages: initialAreas, in: context)
            try? context.save()
            if storage == .study {
                SubjectiveInkLog.write("question_open", ctx, SimplePayload(page_count: progress?.pageCount, note: "choice"))
            }
            #if DEBUG
            // 调试：-debugAddArea YES 选择题没有书写区时加一个
            if UserDefaults.standard.bool(forKey: "debugAddArea"), let progress, progress.pageCount == 0 {
                progress.pageCount = 1
                try? context.save()
            }
            #endif
        }
    }
}
