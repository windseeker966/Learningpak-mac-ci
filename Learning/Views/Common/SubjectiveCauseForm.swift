import SwiftUI

/// 主观题自评里没做对的各问：选错误类型（可多选）、指出弄混的知识点、写原因。原题和 AI 改编题共用
struct SubjectiveCauseForm: View {
    /// 要写错因的小问
    let labels: [String]
    /// 题目只有一问：标题不写编号
    let single: Bool
    let options: [SubjectiveErrorType]
    let pack: StudyPack
    /// 「两个概念混淆了」时可选的知识点
    let confusionCandidates: (String) -> [String]
    /// 紧凑样式（AI 改编题里）：三列、不显示错误类型的说明
    var compact = false
    @Binding var form: SubjectiveAssessmentRules.Form

    var body: some View {
        ForEach(labels, id: \.self) { label in
            Divider()
            Text(single ? "错在哪里？（可多选）" : "\(label) 错在哪里？（可多选）").font(.subheadline.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: compact ? 3 : 2), spacing: 8) {
                ForEach(options, id: \.self) { causeButton($0, part: label) }
            }
            if form.hasCause(.confused, part: label) {
                confusionPicker(label)
            }
            let other = form.hasCause(.other, part: label)
            TextField(other ? "写下错误原因（必填）" : "写下具体原因（选填）",
                      text: Binding(get: { form.notes[label] ?? "" }, set: { form.notes[label] = $0 }),
                      axis: .vertical)
                .lineLimit(compact ? 1...4 : 2...5)
                .padding(compact ? 10 : 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .draftTappable()
        }
    }

    private func causeButton(_ t: SubjectiveErrorType, part label: String) -> some View {
        let picked = form.hasCause(t, part: label)
        return Button {
            form.toggleCause(t, part: label)
        } label: {
            if compact {
                Label(t.label, systemImage: picked ? "checkmark.square.fill" : "square")
                    .font(.callout)
                    .foregroundStyle(picked ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background((picked ? Color.accentColor : .secondary).opacity(picked ? 0.12 : 0.05),
                                in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(alignment: .top) {
                    Image(systemName: picked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(picked ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.label)
                        Text(t.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .background((picked ? Color.accentColor : .secondary).opacity(picked ? 0.12 : 0.05),
                            in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
        .draftTappable()
    }

    @ViewBuilder
    private func confusionPicker(_ label: String) -> some View {
        let candidates = confusionCandidates(label)
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                Text("把哪些知识点弄混了？（可多选，选填）").font(.caption.bold())
                ForEach(candidates, id: \.self) { pointButton($0, part: label).font(.callout) }
            }
        } else if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("把哪些知识点弄混了？（可多选，选填）").font(.subheadline.bold())
                ForEach(candidates, id: \.self) { pointButton($0, part: label) }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func pointButton(_ id: String, part label: String) -> some View {
        let picked = form.isConfused(id, part: label)
        return Button {
            form.toggleConfused(id, part: label)
        } label: {
            Label(pack.pointTitle(id), systemImage: picked ? "checkmark.square.fill" : "square")
                .foregroundStyle(picked ? Color.accentColor : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draftTappable()
    }
}
