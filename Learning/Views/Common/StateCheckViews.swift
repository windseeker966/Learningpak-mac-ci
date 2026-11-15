import SwiftData
import SwiftUI

extension View {
    /// 底部的状态询问条和学习节奏提醒（顶部是标签栏和工具栏）（见 StateCheckSession）。挂在根视图和各个全屏覆盖的页面上：覆盖页面会挡住根视图上的询问条
    func stateCheckBanner() -> some View { modifier(StateCheckBanner()) }
}

private struct StateCheckBanner: ViewModifier {
    @Environment(StateCheckSession.self) private var stateCheck
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let reminder = stateCheck.reminder {
                    reminderCard(reminder)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let trigger = stateCheck.pending {
                    card(trigger)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 16)
        }
        .animation(.easeOut(duration: 0.2), value: stateCheck.pending)
        .animation(.easeOut(duration: 0.2), value: stateCheck.reminder)
    }

    private func reminderCard(_ reminder: StudyReminder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(reminder))
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(reminder)).font(.headline)
                Text(Self.detail(reminder)).font(.caption).foregroundStyle(.secondary)
            }
            Button("休息一下") { stateCheck.takeBreak() }
                .buttonStyle(.borderedProminent)
            switch reminder {
            case .rest:
                Button("再学 10 分钟") { stateCheck.snoozeRest() }
                    .buttonStyle(.bordered)
            case .struggling:
                Button("还好，继续") { stateCheck.keepGoing() }
                    .buttonStyle(.bordered)
            case .dayLight, .dayEnough:
                Button("知道了") { stateCheck.dismissReminder() }
                    .buttonStyle(.bordered)
            }
            Button("关掉", systemImage: "xmark") { stateCheck.dismissReminder() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .draftTappable()
    }

    private func title(_ reminder: StudyReminder) -> String {
        switch reminder {
        case .rest: "已经连续学了 \(Int((stateCheck.streakSeconds / 60).rounded())) 分钟"
        case .dayLight: "今天已经学了 2 小时"
        case .dayEnough: "今天已经学了 3 小时"
        case .struggling: struggleTitle
        }
    }

    private var struggleTitle: String {
        guard let s = stateCheck.struggle else { return "最近答得不太顺" }
        switch s.signal {
        case .rushing: return "最近 \(s.count) 题答得比平时快很多，错了 \(s.wrong) 道"
        case .moreWrong:
            return "最近 \(s.count) 题错了 \(s.wrong) 道，平时大约 \(Int(s.usualWrong.rounded())) 道"
        case .skipping: return "刚才连着跳过了 \(s.skips) 道"
        }
    }

    private static func icon(_ reminder: StudyReminder) -> String {
        switch reminder {
        case .rest: "cup.and.saucer"
        case .dayLight, .dayEnough: "clock.badge.checkmark"
        case .struggling: "battery.25percent"
        }
    }

    private static func detail(_ reminder: StudyReminder) -> String {
        switch reminder {
        case .rest: "起来走走，离开 10～15 分钟再回来；中途切出去一下不算休息"
        case .dayLight: "之后换轻一点的：到期复习、生词、订正，新内容留到明天上午"
        case .dayEnough: "再学下去容易累，剩下的留给明天吧"
        case .struggling: "可能有点累了，要不要休息一下？"
        }
    }

    private func card(_ trigger: StateCheckTrigger) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("现在状态怎么样？").font(.headline)
                Text(Self.reason(trigger)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(StudyState.allCases, id: \.self) { state in
                Button(state.label) { stateCheck.answer(state, in: context) }
                    .buttonStyle(.bordered)
            }
            Button("不记", systemImage: "xmark") { stateCheck.dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .draftTappable()
    }

    private static func reason(_ trigger: StateCheckTrigger) -> String {
        switch trigger {
        case .launch: "开始学习"
        case .firstBlock: "刚做完今天的第一组"
        case .returned: "离开了一阵"
        case .afterBreak: "休息回来"
        case .longStudy: "已经连续学了一段时间"
        case .reviewDone: "刚结束一次复习"
        case .manual: "记录一下"
        }
    }
}

/// 工具栏上的「状态」菜单：记录现在的状态、开始休息（看手机额度的学习码已关闭）
struct StateCheckMenu: View {
    @Environment(StateCheckSession.self) private var stateCheck
    @State private var showCode = false

    var body: some View {
        Menu("状态", systemImage: "gauge.with.dots.needle.50percent") {
            Button("记录现在的状态", systemImage: "square.and.pencil") { stateCheck.askManually() }
            Button("休息一下", systemImage: "cup.and.saucer") { stateCheck.startBreak() }
            // 手机额度已关闭
            // Button("手机学习码", systemImage: "iphone.and.arrow.forward") {
            //     stateCheck.studyCodeShown()
            //     showCode = true
            // }
        }
        // .sheet(isPresented: $showCode) { StudyCodeSheet() }  // 手机额度已关闭
    }
}

/// 手机额度的学习码：在手机的时间记录 App 里输入这三个数（见 StudyCode）
struct StudyCodeSheet: View {
    @Environment(StateCheckSession.self) private var stateCheck
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // codeSeconds 每 30 秒更新一次，码跟着变
        let c = stateCheck.studyCode()
        NavigationStack {
            VStack(spacing: 28) {
                HStack(spacing: 48) {
                    number("学习（分钟）", "\(c.minutes)")
                    number("开始（次）", "\(c.starts)")
                    number("校验码", c.code)
                }
                Text("在手机「时间记录」里点「输入学习码」，依次填这三个数。码只在今天（早上 5 点前算前一天）有效，学得越多越新，输入最新的一次即可，可以随时重复输入。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                Text("学习分钟按 App 在前台的时间算，不含「浏览器」标签页；一段连续学习满 10 分钟算开始一次。手机复习 App 上学的时间同步过来后也算在内"
                     + (c.phoneMinutes > 0 ? "（今天手机上 \(c.phoneMinutes) 分钟）。" : "。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .padding(32)
            .navigationTitle("手机学习码 · \(c.day)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private func number(_ title: String, _ value: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
