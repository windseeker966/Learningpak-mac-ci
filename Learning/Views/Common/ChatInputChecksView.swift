#if DEBUG
import SwiftUI

/// 长讲评中的键盘输入检查，只把保存结果编码到内存。
struct ChatInputChecksView: View {
    @State private var session = ChatSession()
    @State private var saves = 0
    @State private var bottom = 0
    var body: some View {
        ZoomablePageScrollView(draftEnabled: false, bottomRequest: bottom) {
            Card {
                Text("AI 讲评键盘检查 · 已保存 \(saves) 次草稿").font(.headline)
                ChatThreadView(session: session, placeholder: "在这里输入长问题，检查键盘响应")
            }
            .padding(20)
        }
        .onAppear {
            let answer = String(repeating: "先判断已知条件，再代入 $a^2+b^2=c^2$ 检查结果。这里要区分条件与结论。\n\n", count: 24)
            session.restore(SavedConversation(system: "输入检查", context: [],
                messages: [.init(role: "assistant", text: answer, shown: answer)],
                draft: "", pendingQuote: nil, partialText: "", error: nil))
            session.onSave = { saved in
                _ = try? JSONEncoder().encode(saved)
                saves += 1
            }
            bottom = 1
        }
    }
}
#endif
