import SwiftData
import SwiftUI

/// 一本书的笔记：自己添加的笔记（文字和书写区），以及各题的订正笔记（文字和手写）。
/// 页面上的笔迹和其他页面一样保存
struct BookNotesView: View {
    let pack: StudyPack

    @Environment(\.modelContext) private var context
    // 旧的在前：新笔记加在最后，前面笔记的书写区位置不变，笔迹不会错位
    @Query(sort: \BookNote.createdAt) private var allNotes: [BookNote]
    @Query private var attempts: [AttemptRecord]
    @Query private var subjective: [SubjectiveAttempt]
    @Query private var variants: [VariantAttempt]
    @AppStorage("draft.enabled") private var draftEnabled = true
    @State private var tapTargets = DraftTapTargets()
    @State private var resetZoomRequest = 0
    @State private var draft = ""

    private var draftKey: String { "\(pack.id)|notes" }
    private var notes: [BookNote] { allNotes.filter { $0.packID == pack.id } }

    /// 一条订正笔记：属于哪道题、文字、手写、更新时间
    private struct Entry: Identifiable {
        let id: String
        let questionID: String
        let title: String
        let isVariant: Bool
        let text: String?
        let ink: [Data]
        let updatedAt: Date
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        func add(_ r: any CorrectionNoted, id: String, questionID: String, variant: Bool) {
            let text = r.correctionNote.flatMap { $0.isEmpty ? nil : $0 }
            let ink = r.correctionInk
            guard text != nil || !ink.isEmpty else { return }
            out.append(Entry(id: id, questionID: questionID, title: title(questionID, variant: variant),
                             isVariant: variant, text: text, ink: ink,
                             updatedAt: r.correctionUpdatedAt ?? r.createdAt))
        }
        for a in attempts where a.packID == pack.id {
            add(a, id: "a|\(ObjectIdentifier(a))", questionID: a.questionID, variant: false)
        }
        for a in subjective where a.packID == pack.id {
            add(a, id: "s|\(ObjectIdentifier(a))", questionID: a.questionID, variant: false)
        }
        for v in variants where v.packID == pack.id {
            add(v, id: "v|\(ObjectIdentifier(v))", questionID: v.originalID, variant: true)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func title(_ qid: String, variant: Bool) -> String {
        let section = pack.questionSection[qid] ?? ""
        let name = pack.questions[qid].map { "第 \($0.num) 题" } ?? pack.subjective[qid].map { "\($0.kindLabel) \($0.num)" } ?? qid
        return "\(section) \(name)" + (variant ? "的 AI 改编题" : "")
    }

    var body: some View {
        ZoomablePageScrollView(draftEnabled: draftEnabled, resetZoomRequest: resetZoomRequest) {
            VStack(alignment: .leading, spacing: 20) {
                myNotes
                corrections
                if draftEnabled { Color.clear.frame(height: 360) }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(draftPageSpace))
            .environment(\.draftTapTargets, tapTargets)
            .overlay {
                DraftCanvas(key: draftKey, enabled: draftEnabled, tapTargets: tapTargets).id(draftKey)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button(draftEnabled ? "关闭草稿模式" : "开启草稿模式",
                           systemImage: draftEnabled ? "pencil.slash" : "pencil.tip") { draftEnabled.toggle() }
                    Button("恢复原大小", systemImage: "arrow.down.right.and.arrow.up.left") { resetZoomRequest += 1 }
                } label: {
                    Label("草稿", systemImage: draftEnabled ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                } primaryAction: {
                    draftEnabled.toggle()
                }
            }
        }
    }

    // MARK: - 自己的笔记

    private var myNotes: some View {
        Card {
            Text("我的笔记").font(.headline)
            Text("按书保存。每条笔记可以添加书写区手写，笔迹和其他页面一样保存。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(notes) { note in
                NoteRow(note: note, pageKey: draftKey)
                Divider()
            }
            TextField("写一条笔记……", text: $draft, axis: .vertical)
                .lineLimit(2...8)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .draftTappable()
            HStack {
                Spacer()
                Button("添加手写笔记", systemImage: "pencil.and.scribble") { addNote(handwriting: true) }
                    .buttonStyle(.bordered)
                    .draftTappable()
                Button("添加笔记", systemImage: "plus") { addNote(handwriting: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .draftTappable()
            }
        }
    }

    /// handwriting：带一个书写区，文字可以为空
    private func addNote(handwriting: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard handwriting || !text.isEmpty else { return }
        let note = BookNote(packID: pack.id, text: text)
        if handwriting { note.areaCount = 1 }
        context.insert(note)
        try? context.save()
        draft = ""
    }

    // MARK: - 订正笔记

    private var corrections: some View {
        Card {
            Text("订正笔记").font(.headline)
            Text("在各题的订正笔记里写的文字和手写。也可以直接在这一页上随手写，笔迹会保存。")
                .font(.caption).foregroundStyle(.secondary)
            let list = entries
            if list.isEmpty {
                Text("还没有订正笔记。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink {
                        destination(e)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            if e.isVariant { Image(systemName: "wand.and.stars").foregroundStyle(.purple) }
                            Text(e.title).font(.body.bold()).foregroundStyle(e.isVariant ? .purple : .primary)
                            Spacer()
                            Text(e.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .draftTappable()
                    if let text = e.text { Text(text).font(.callout) }
                    if !e.ink.isEmpty { CorrectionInkImages(images: e.ink) }
                }
            }
        }
        // 上面的笔记变高变矮时，这一块上随手写的笔迹跟着移动
        .draftInkAnchor(draftKey, name: "corrections")
    }

    /// 点标题：选择题、主观题进错题重做；改编题看这道原题的全部改编题
    @ViewBuilder
    private func destination(_ e: Entry) -> some View {
        if e.isVariant {
            ScrollView {
                VariantHistoryCard(pack: pack, originalID: e.questionID).padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(e.title)
            .navigationBarTitleDisplayMode(.inline)
        } else if let q = pack.questions[e.questionID] {
            RedoView(pack: pack, question: q)
        } else if let q = pack.subjective[e.questionID] {
            SubjectiveRedoView(pack: pack, question: q)
        } else {
            Text("这道题已不在教辅包中。").foregroundStyle(.secondary)
        }
    }
}

/// 自己的一条笔记：直接改文字（自动保存），可以添加书写区，可以删除
private struct NoteRow: View {
    @Bindable var note: BookNote
    let pageKey: String
    @Environment(\.modelContext) private var context
    @State private var frames: [Int: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("笔记", text: $note.text, axis: .vertical)
                .lineLimit(1...10)
                .onChange(of: note.text) {
                    note.updatedAt = .now
                    try? context.save()
                }
                .draftTappable()
            VStack(alignment: .leading, spacing: 20) {
                WritingAreaList(count: note.areaCount, ctx: nil, frames: $frames)
            }
            HStack(spacing: 16) {
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("添加书写区", systemImage: "plus.rectangle.on.rectangle") { setAreas(note.areaCount + 1) }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .draftTappable()
                if note.areaCount > 0 {
                    DeleteAreaMenu(count: note.areaCount) { i in
                        guard WritingAreaList.deleteArea(i, frames: frames, draftKey: pageKey) else { return }
                        setAreas(note.areaCount - 1)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .draftTappable()
                }
                Button("删除笔记", systemImage: "trash", role: .destructive) { delete() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .draftTappable()
            }
        }
        // 每条笔记一个锚点：前面的笔记变高变矮时，书写区里的笔迹跟着这条笔记移动
        .draftInkAnchor(pageKey, name: "note-\(note.id.uuidString)")
    }

    private func setAreas(_ n: Int) {
        note.areaCount = max(n, 0)
        note.updatedAt = .now
        try? context.save()
    }

    /// 删除笔记时把它书写区里的笔迹一起移走（从后往前删，前面书写区的位置不受影响）
    private func delete() {
        for i in stride(from: note.areaCount - 1, through: 0, by: -1) {
            _ = WritingAreaList.deleteArea(i, frames: frames, draftKey: pageKey)
        }
        context.delete(note)
        try? context.save()
    }
}
