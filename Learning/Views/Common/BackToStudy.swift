import SwiftUI

/// 复习、错题本里提交这次作答后：回到最开始学这道题的地方（那一轮的讲解和题目）
struct BackToStudyTarget {
    let pack: StudyPack
    let questionID: String
}

struct BackToStudyButton: View {
    let pack: StudyPack
    let questionID: String
    let action: (BackToStudyTarget) -> Void

    var body: some View {
        if let loc = pack.questionLocation(questionID) {
            Button {
                action(BackToStudyTarget(pack: pack, questionID: questionID))
            } label: {
                Label("回到最开始学这道题的地方（\(loc.section.section.id) 第 \(loc.roundIndex + 1) 轮）",
                      systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .draftTappable()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// 配合 BackToStudyButton：target 有值时打开学习页并定位到这道题。放在缩放容器外面（导航不跨宿主）
    func backToStudyDestination(_ target: Binding<BackToStudyTarget?>) -> some View {
        navigationDestination(isPresented: Binding(get: { target.wrappedValue != nil },
                                                   set: { if !$0 { target.wrappedValue = nil } })) {
            if let t = target.wrappedValue, let loc = t.pack.questionLocation(t.questionID) {
                StudySessionView(pack: t.pack, section: loc.section,
                                 start: StudyPosition(roundIndex: loc.roundIndex, page: .question(loc.questionIndex)))
            }
        }
    }
}
