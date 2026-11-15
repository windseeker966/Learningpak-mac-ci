import SwiftData
import SwiftUI
import UIKit

/// 划词悬浮窗（文章和内置浏览器的网页共用）：单词或短语给出在这句里的意思（不是原形时说明形态和原形），
/// 可以加入或移出生词本；划选一整句或更长时给出翻译。流程见 WordLookupSession
struct WordPopover: View {
    let action: PassageWordAction

    @Environment(\.modelContext) private var context
    @Query private var matches: [VocabEntry]
    @State private var session: WordLookupSession

    init(selection: VocabSelection, action: PassageWordAction) {
        self.action = action
        _session = State(initialValue: WordLookupSession(
            selection: selection, isWord: PassageParagraphText.isWordLike(selection.text)))
        let key = selection.key
        _matches = Query(filter: #Predicate<VocabEntry> { $0.key == key })
    }

    private var runner: StreamRunner { session.runner }
    private var selection: String { session.selection.text }
    private var isWord: Bool { session.isWord }
    private var entry: VocabEntry? { matches.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(selection)
                    .font(.system(isWord ? .title3 : .callout, design: .serif).weight(isWord ? .bold : .regular))
                    .lineLimit(isWord ? 2 : 4)
                if isWord, let phonetic = shownMeaning?.phonetic {
                    Text(phonetic).font(.callout).foregroundStyle(.secondary)
                }
                if isWord {
                    Button("朗读", systemImage: "speaker.wave.2") { Speech.speak(entry?.word ?? selection) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
                if entry != nil {
                    Label("生词本", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                }
            }
            Divider()
            content
            footer
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task { session.start(addOnOpen: action == .add, in: context) }
        .onDisappear { session.finish() }
    }

    /// 显示的释义：生词本里存的，或正在查的
    private var shownMeaning: VocabAI.Meaning? {
        if let e = entry, e.meaning != nil { return e.storedMeaning }
        return runner.text.isEmpty ? nil : VocabAI.Meaning(runner.text)
    }

    @ViewBuilder
    private var content: some View {
        if let e = entry, e.meaning != nil {
            MeaningView(meaning: e.storedMeaning)
        } else if !session.configured {
            Text("尚未配置模型，请到「设置」中填写。").font(.callout).foregroundStyle(.secondary)
        } else if let error = runner.error {
            Text(error).font(.callout).foregroundStyle(.red)
            Button("重试") { session.retry() }
        } else if runner.text.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                Text(isWord ? "正在查这个词在句中的意思…" : "正在翻译…").font(.callout).foregroundStyle(.secondary)
            }
        } else if isWord {
            MeaningView(meaning: VocabAI.Meaning(runner.text))
        } else {
            Text(LocalizedStringKey(runner.text)).font(.callout).textSelection(.enabled)
        }
    }

    /// 底部：这次请 AI 生成的结果标出所用模型（直接读取生词本里存的释义时不标），右边是加入 / 移出生词本
    @ViewBuilder
    private var footer: some View {
        let generated = runner.usage != nil && !runner.text.isEmpty
        if generated || entry != nil || isWord {
            HStack {
                if generated { ModelBadge(usage: runner.usage) }
                Spacer()
                if entry != nil {
                    Button("移出生词本", systemImage: "trash", role: .destructive) { session.remove() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if isWord {
                    Button("加入生词本", systemImage: "plus.rectangle.on.rectangle") { session.add() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }
}

/// 释义：在句中的意思、原形与形态、其他常见意思
struct MeaningView: View {
    let meaning: VocabAI.Meaning

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = meaning.meaning { Text(m).font(.body) }
            if let form = meaning.form {
                Label { Text("原形：\(form)") } icon: { Image(systemName: "arrow.uturn.backward") }
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let note = meaning.note {
                Text("其他意思：\(note)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// 在选区旁弹出划词悬浮窗，箭头指向选中的文字（文章段落和网页共用）
@MainActor
enum WordPopoverPresenter {
    static func present(_ content: AnyView, from view: UIView, rect: CGRect) {
        guard let presenter = topController(view.window?.rootViewController) else { return }
        let host = UIHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        host.modalPresentationStyle = .popover
        if let pop = host.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = rect
            pop.permittedArrowDirections = [.up, .down]
            // 悬浮窗默认是半透明材质，背后的正文会透出来，影响阅读
            pop.backgroundColor = .systemBackground
            pop.delegate = delegate
        }
        presenter.present(host, animated: true)
    }

    private static let delegate = Delegate()

    private final class Delegate: NSObject, UIPopoverPresentationControllerDelegate {
        /// 窄屏上也保持悬浮窗，不变成全屏
        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }
    }

    private static func topController(_ root: UIViewController?) -> UIViewController? {
        var top = root
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
