import SwiftUI

/// 计算测速的一轮：大号题目，下面是数字键盘（带「余」键）。答对直接下一题，上方显示上一题的用时；
/// 答错显示正确答案，点「继续」后接着做。做完显示本轮结果
struct FactDrillView: View {
    let onClose: () -> Void

    @Environment(\.modelContext) private var context
    @State private var session: FactDrillSession
    @State private var showGuide = false

    init(drills: [FactDrill], onClose: @escaping () -> Void) {
        _session = State(initialValue: FactDrillSession(drills: drills))
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.phase == .finished {
                    ScrollView {
                        FactResultsView(results: session.results)
                        Button { onClose() } label: { Text("完成").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .padding(.top, 8)
                    }
                } else {
                    drill
                }
            }
            .padding(32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(session.phase == .finished ? "测速结果"
                             : "计算测速 \(session.answeredBefore + min(session.index + 1, session.count)) / \(session.answeredBefore + session.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成", action: onClose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("背诵表", systemImage: "text.book.closed") { showGuide = true }
                }
            }
        }
        .onChange(of: showGuide) { _, open in open ? session.pauseTiming() : session.resumeTiming() }
        .sheet(isPresented: $showGuide) {
            NavigationStack {
                FactGuideView()
                    .toolbar { Button("关闭") { showGuide = false } }
            }
        }
        .onAppear { session.start(in: context) }
    }

    private var drill: some View {
        VStack(spacing: 24) {
            ProgressView(value: Double(session.answeredBefore + session.index), total: Double(max(session.answeredBefore + session.count, 1)))
            lastLine
            if let q = session.current {
                VStack(spacing: 12) {
                    if session.isRetry {
                        Text("刚才答错的题，再做一次").font(.callout).foregroundStyle(.orange)
                    }
                    HStack(spacing: 20) {
                        Text("\(q.prompt) =")
                        if session.phase == .showingAnswer {
                            Text(session.last?.given ?? "").strikethrough().foregroundStyle(.red)
                        } else {
                            Text(session.input.isEmpty ? "?" : session.input)
                                .foregroundStyle(session.input.isEmpty ? .tertiary : .primary)
                        }
                    }
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    if session.phase == .showingAnswer, let last = session.last {
                        Text("\(last.prompt) = \(last.answer)").font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                        Text("把整个式子念一遍，再继续").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if session.phase == .showingAnswer {
                Button { session.proceed() } label: { Text("继续").frame(maxWidth: .infinity, minHeight: 56) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 420)
            } else {
                keypad
            }
        }
    }

    /// 上一题答对时显示用时，慢于熟练线的标橙色
    @ViewBuilder private var lastLine: some View {
        if session.phase == .answering, let last = session.last, last.correct {
            Label("\(last.prompt) = \(last.answer)  \(seconds(last.seconds))",
                  systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(last.isFluent ? .green : .orange)
        } else {
            Text(" ").font(.callout)
        }
    }

    private enum Key: Hashable {
        case digit(Int), remainder, delete
    }

    private var keypad: some View {
        let rows: [[Key]] = [[.digit(1), .digit(2), .digit(3)], [.digit(4), .digit(5), .digit(6)],
                             [.digit(7), .digit(8), .digit(9)], [.remainder, .digit(0), .delete]]
        return VStack(spacing: 10) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in keyButton(key) }
                }
            }
            Button { session.submit() } label: { Text("确定").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 56) }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canSubmit)
        }
        .frame(maxWidth: 420)
    }

    private func keyButton(_ key: Key) -> some View {
        Button {
            switch key {
            case .digit(let d): session.type(d)
            case .remainder: session.typeRemainder()
            case .delete: session.deleteBackward()
            }
        } label: {
            Group {
                switch key {
                case .digit(let d): Text("\(d)")
                case .remainder: Text("余")
                case .delete: Image(systemName: "delete.left")
                }
            }
            .font(.system(size: 30, weight: .medium, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.bordered)
    }
}

private func seconds(_ s: Double) -> String { String(format: "%.1f 秒", s) }

/// 一轮或一天的作答结果：总的和各类的正确率、平均用时、答得熟的题数，答错的和最慢的题
struct FactResultsView: View {
    let results: [FactResult]

    var body: some View {
        let firsts = results.filter { !$0.retry }
        VStack(alignment: .leading, spacing: 20) {
            summaryLine(ArithmeticFacts.summary(results), title: "共").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                ForEach(FactKind.allCases, id: \.self) { kind in
                    let s = ArithmeticFacts.summary(firsts.filter { $0.factKind == kind })
                    if s.count > 0 {
                        GridRow {
                            Text(kind.label).bold()
                            Text("对 \(s.correct)/\(s.count)")
                            Text(s.averageSeconds.map { "平均 \(seconds($0))" } ?? "—")
                            Text("熟 \(s.fluent) 题").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.body.monospacedDigit())
            let wrong = firsts.filter { !$0.correct }
            if !wrong.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("答错的").font(.headline)
                    ForEach(Array(wrong.enumerated()), id: \.offset) { _, r in
                        Text("\(r.prompt) = \(r.answer)（写了 \(r.given)）").foregroundStyle(.red)
                    }
                }
            }
            let slow = firsts.filter { $0.correct && !$0.isFluent }.sorted { $0.seconds > $1.seconds }
            if !slow.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("答对但慢的（超过熟练线）").font(.headline)
                    ForEach(Array(slow.prefix(10).enumerated()), id: \.offset) { _, r in
                        Text("\(r.prompt) = \(r.answer)  \(seconds(r.seconds))").foregroundStyle(.orange)
                    }
                }
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryLine(_ s: FactSummary, title: String) -> Text {
        Text("\(title) \(s.count) 题 · 对 \(s.correct) · 熟 \(s.fluent)"
             + (s.averageSeconds.map { " · 平均 \(seconds($0))" } ?? ""))
    }
}

/// 复习首页：今天还没测速时显示测速按钮，测过了不显示；下面总有「背诵表和方法」
struct FactDrillHomeButton: View {
    let drills: [FactDrill]
    let onStart: () -> Void

    var body: some View {
        if !FactDrill.doneToday(drills) {
            Button(action: onStart) {
                VStack(spacing: 6) {
                    Label("计算测速", systemImage: "number").font(.title.bold())
                    if let left = FactDrill.unfinishedToday(drills)?.pending.count {
                        Text("继续 · 还剩 \(left) 题").font(.title3)
                    } else {
                        Text("今日 \(FactDrill.perKind * FactKind.practiced.count) 题 · 约 2 分钟").font(.title3)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .frame(maxWidth: 720)
        }
        NavigationLink {
            FactGuideView()
        } label: {
            Label("计算的背诵表和方法", systemImage: "text.book.closed")
        }
        .buttonStyle(.bordered)
        .tint(.teal)
        .controlSize(.large)
    }
}

/// 「全部 › 计算测速」里能打开的页面
enum FactPage: Hashable {
    case guide, stats
}

/// 复习页「全部」里的一节：开始测速、背诵表和方法、记录。
/// 背诵表和记录用按钮交给 onOpen，由列表页 navigationDestination 打开：List 的一行里放 NavigationLink 会把整行当成链接，
/// 一行两个链接时点哪里都依次打开两个（buttonStyle 也改不了）
struct FactDrillSection: View {
    let drills: [FactDrill]
    let onStart: () -> Void
    let onOpen: (FactPage) -> Void

    var body: some View {
        let done = FactDrill.doneToday(drills)
        Section {
            HStack(spacing: 12) {
                Button(action: onStart) {
                    Label(FactDrill.unfinishedToday(drills) != nil ? "继续测速" : done ? "再测一轮" : "开始测速",
                          systemImage: "play.fill").foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                Button("背诵表和方法", systemImage: "text.book.closed") { onOpen(.guide) }
                    .buttonStyle(.bordered)
                Button("记录", systemImage: "chart.line.uptrend.xyaxis") { onOpen(.stats) }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            Text("\(FactKind.practiced.map(\.label).joined(separator: "、"))各抽 \(FactDrill.perKind) 题，用屏幕键盘作答，从出题到点「确定」计时，自动判对错。上次答错、答得慢的更容易抽到；答错的在本轮最后再出一次，不计入成绩。熟练线：\(Int(FactKind.add.fluentSeconds)) 秒，带余除法 \(Int(FactKind.rem.fluentSeconds)) 秒。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("计算测速").font(.headline).textCase(nil)
                Spacer()
                Text(todayText).font(.caption).textCase(nil)
            }
        }
    }

    private var todayText: String {
        let today = drills.filter { Calendar.current.isDateInToday($0.createdAt) }.flatMap(\.results)
        guard FactDrill.doneToday(drills), let avg = ArithmeticFacts.summary(today).averageSeconds else { return "今天还没测" }
        return "今天平均 \(seconds(avg))"
    }
}

/// 测速记录：每轮的成绩（点开看明细）、现在还不熟的事实
struct FactStatsView: View {
    let drills: [FactDrill]

    var body: some View {
        List {
            Section("每轮成绩") {
                let rounds = drills.filter { !$0.results.isEmpty }.reversed()
                if rounds.isEmpty {
                    Text("还没有测过").foregroundStyle(.secondary)
                }
                ForEach(Array(rounds)) { d in
                    NavigationLink {
                        ScrollView { FactResultsView(results: d.results).padding(24) }
                            .navigationTitle(d.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        let s = d.summary
                        HStack {
                            Text(d.createdAt.formatted(date: .abbreviated, time: .shortened))
                            if d.finishedAt == nil { Text("没做完").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("对 \(s.correct)/\(s.count) · 熟 \(s.fluent)"
                                 + (s.averageSeconds.map { " · 平均 \(seconds($0))" } ?? ""))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            let weak = weakest
            if !weak.isEmpty {
                Section {
                    ForEach(weak, id: \.0.key) { fact, stat in
                        HStack {
                            Text(fact.display).monospacedDigit()
                            Spacer()
                            Text(stat.correct ? seconds(stat.seconds) : "上次答错")
                                .monospacedDigit()
                                .foregroundStyle(stat.correct ? .orange : .red)
                        }
                    }
                } header: {
                    Text("还不熟的（按最近一次成绩）")
                }
            }
        }
        .navigationTitle("测速记录")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 最近一次答错或慢于熟练线的事实，答错的在前，其余按用时从慢到快，最多 20 个
    private var weakest: [(Fact, FactStat)] {
        FactDrill.stats(drills).compactMap { key, stat -> (Fact, FactStat)? in
            guard let fact = Fact(key: key), !stat.correct || stat.seconds > fact.kind.fluentSeconds else { return nil }
            return (fact, stat)
        }
        .sorted { ($0.1.correct ? 1 : 0, -$0.1.seconds) < ($1.1.correct ? 1 : 0, -$1.1.seconds) }
        .prefix(20)
        .map { $0 }
    }
}
