import SwiftUI
import UIKit

/// 单独作答的窗口：要在 GoodNotes 里演算、书写的题，点「单独窗口作答」
/// 在另一个窗口里作答（和 GoodNotes 并排，主观题贴图片），主窗口这道题显示占位。
/// 学习页、复习页的主观题和选择题都可以（英语阅读题除外），学习页的讲解也可以（点「单独窗口」，边看边记笔记）。
/// 窗口里点「下一题」（讲解是「开始做题」），主窗口翻到下一页，下一页能放进窗口（题目、下一轮的讲解）就接着在窗口里做，
/// 不能（英语题、读后练习、做完了）就回到主窗口。
/// 回到主窗口时关掉窗口，不留在后台被主窗口盖着（下次调出的是新窗口，由系统摆放）。
/// 回到主窗口后 GoodNotes 也被盖住，打开窗口时用链接把它调出来。
/// 窗口全屏、GoodNotes 摆在下面时，窗口下方留出 GoodNotes 区（见 SubjectiveWindowView）：
/// 点一下窗口就会被系统提到前面盖住 GoodNotes（App 拦不住），这时点 GoodNotes 区把它调回来。
@MainActor @Observable
final class SubjectiveWindow {
    static let shared = SubjectiveWindow()
    static let sceneID = "subjective-window"
    static let companionKey = "subjectiveWindow.openGoodNotes"
    /// 调出 GoodNotes 用的链接。GoodNotes 没有公开的链接：只写前缀（goodnotes://、goodnotes5://、goodnotes6://）
    /// 会被当成导入文件，弹「不支持的文件类型」；它程序里的 x-callback-url 动作 wakeup 只切到前台，不弹窗。可以在设置里改
    static let companionURLKey = "subjectiveWindow.goodNotesURL"
    static let defaultCompanionURL = "goodnotes5://x-callback-url/wakeup"
    /// 以前的默认值和试过的只写前缀的链接，都会弹窗：存的是这些就换回新的默认值
    private static let poppingCompanionURLs: Set<String> = ["goodnotes://", "goodnotes5://", "goodnotes6://"]
    static var opensCompanion: Bool { UserDefaults.standard.object(forKey: companionKey) as? Bool ?? true }
    /// 启动时调用：设置里存的是会弹窗的旧链接，就去掉，改用默认值
    static func migrateCompanionURL() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.string(forKey: companionURLKey),
              poppingCompanionURLs.contains(stored.trimmingCharacters(in: .whitespaces)) else { return }
        defaults.removeObject(forKey: companionURLKey)
    }
    static var companionURL: URL? {
        URL(string: (UserDefaults.standard.string(forKey: companionURLKey) ?? defaultCompanionURL)
            .trimmingCharacters(in: .whitespaces))
    }

    struct Job: Identifiable {
        let id = UUID()
        let packID: String
        let questionID: String
        /// 学习、复习等，同一道题在不同页面上算不同的作答
        let place: String
        let title: String
        /// 在窗口里做什么：「作答」「看讲解」，用在占位和「回到主窗口…」上
        var activity = "作答"
        let nextLabel: String
        let onNext: () -> Void
        /// 窗口里显示的题目卡片；参数是卡片里「下一题」要调用的动作
        let content: (@escaping () -> Void) -> AnyView

        func matches(packID: String, questionID: String, place: String) -> Bool {
            self.packID == packID && self.questionID == questionID && self.place == place
        }
    }

    /// 正在窗口里作答的题
    private(set) var job: Job?
    /// 窗口里点了「下一题」，等主窗口的下一题来接上（见 claim）
    private(set) var continuing = false
    /// 调出 GoodNotes 失败时的提示
    var companionError: String?
    @ObservationIgnored private var companionTask: Task<Void, Never>?
    @ObservationIgnored private weak var scene: UIWindowScene?
    @ObservationIgnored private weak var mainScene: UIWindowScene?
    @ObservationIgnored private var disconnectObserver: NSObjectProtocol?

    private var windowConnected: Bool { scene.map { $0.activationState != .unattached } ?? false }

    /// 调出主观题窗口（已有就用原来那个），等它到前台后再调出 GoodNotes
    func open(_ job: Job, openWindow: OpenWindowAction) {
        self.job = job
        if let scene, windowConnected {
            log("open_existing")
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
        } else {
            log("open_new")
            openWindow(id: Self.sceneID)
        }
        companionTask?.cancel()
        companionError = nil
        guard Self.opensCompanion else { return }
        // 窗口显示出来（前台，不论是否已成为活跃窗口）就调出 GoodNotes。新窗口常停在 foregroundInactive，
        // 等 foregroundActive 会白等到 3 秒上限
        companionTask = Task { @MainActor in
            let start = ContinuousClock.now
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(50))
                if let scene, scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
                    break
                }
            }
            guard !Task.isCancelled, self.job != nil else { return }
            log("companion_open", waited: ContinuousClock.now - start)
            openCompanion(from: scene)
        }
    }

    /// 用链接调出 GoodNotes；设置页的「试一下」也用它
    func openCompanion(from scene: UIScene? = nil) {
        guard let url = Self.companionURL else {
            companionError = "调出 GoodNotes 的链接格式不对，请在设置里检查。"
            return
        }
        let done: (Bool) -> Void = { ok in
            SubjectiveWindow.shared.companionError = ok ? nil
                : "没能用 \(url.absoluteString) 调出 GoodNotes。可以在设置里换一个链接，或关掉自动调出。"
        }
        if let scene { scene.open(url, options: nil, completionHandler: done) }
        else { UIApplication.shared.open(url, completionHandler: done) }
    }

    /// 点了窗口下方的 GoodNotes 区：窗口被点到前面盖住了 GoodNotes，用链接把它调回来
    func returnToCompanion() {
        log("companion_zone")
        openCompanion(from: scene)
    }

    /// 把主观题窗口调到前面
    func activate(openWindow: OpenWindowAction) {
        guard let job else { return }
        open(job, openWindow: openWindow)
    }

    /// 窗口里点「下一题」：主窗口翻到下一题；下一题能放进窗口就由它接上（claim），
    /// 一会儿还没接上就回到主窗口，窗口留在原处
    func next() {
        let job = self.job
        self.job = nil
        continuing = true
        log("next")
        job?.onNext()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard continuing else { return }
            continuing = false
            showMain()
        }
    }

    /// 主窗口翻到的下一题接着在窗口里做
    func claim(_ job: Job) {
        guard continuing else { return }
        continuing = false
        self.job = job
        log("claimed")
    }

    /// 收回到主窗口作答：主窗口重新显示这道题（贴的图片仍在）
    func takeBack() {
        job = nil
        continuing = false
        showMain()
    }

    /// 调回主窗口并关掉单独窗口，不留在后台（下次调出的是新窗口）
    private func showMain() {
        companionTask?.cancel()
        log("show_main")
        if let mainScene {
            UIApplication.shared.requestSceneSessionActivation(mainScene.session, userActivity: nil, options: nil)
        } else {
            // 系统只恢复了这个窗口、主窗口没打开：开一个新的主窗口，不然关掉这个窗口后 App 就没有窗口了
            log("open_main")
            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
        }
        if let scene, windowConnected {
            log("close_window")
            // 马上断开登记：窗口还没关完就又调出时开新窗口，旧窗口关掉时也不会清掉新的作答
            if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
            disconnectObserver = nil
            self.scene = nil
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            log("show_main_after")
        }
    }

    func registerMain(_ scene: UIWindowScene?) {
        guard let scene else { return }
        let changed = scene !== mainScene
        mainScene = scene
        if changed { log("main_registered") }
    }

    /// 主观题窗口大小变化
    func logResize() {
        log("resized")
    }

    /// 窗口排查日志（写进笔迹日志，只记录不改行为）：两个窗口的状态、位置和大小
    private func log(_ event: String, waited: Duration? = nil) {
        func describe(_ scene: UIWindowScene?) -> String {
            guard let scene else { return "nil" }
            let state = ["unattached", "foregroundActive", "foregroundInactive", "background"][max(0, scene.activationState.rawValue + 1) % 4]
            guard let w = scene.windows.first else { return state }
            let r = w.convert(w.bounds, to: w.screen.coordinateSpace)
            return "\(state) (\(Int(r.minX)),\(Int(r.minY))) \(Int(r.width))x\(Int(r.height))"
        }
        var fields = ["main": describe(mainScene), "window": describe(scene), "job": job?.questionID ?? "none"]
        if let waited { fields["waited_ms"] = "\(Int(waited / .milliseconds(1)))" }
        InkLog.write("subjective_window_\(event)", fields)
    }

    /// 主观题窗口出现时登记；用系统按钮关掉窗口时，这道题回到主窗口
    func registerWindow(_ scene: UIWindowScene?) {
        guard let scene, scene !== self.scene else { return }
        self.scene = scene
        log("window_registered")
        // 重新打开 App 时系统可能把上次的窗口恢复出来，这时没有题可做（作答只在内存里）：直接回到主窗口
        if job == nil && !continuing {
            log("restored_empty")
            showMain()
            return
        }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didDisconnectNotification, object: scene, queue: .main) { _ in
            MainActor.assumeIsolated {
                SubjectiveWindow.shared.log("window_disconnected")
                SubjectiveWindow.shared.job = nil
                SubjectiveWindow.shared.scene = nil
            }
        }
    }
}

/// 题目或讲解转到单独窗口后，主窗口这里的占位；窗口里点了「下一题」时，翻到的这一页也先显示占位，接着在窗口里做
private struct DetachedPlaceholder: View {
    let title: String
    var activity = "作答"
    let claim: () -> Void
    @Environment(\.openWindow) private var openWindow
    private let window = SubjectiveWindow.shared

    var body: some View {
        Card {
            Label("\(title)正在单独窗口中\(activity)", systemImage: "rectangle.split.1x2").font(.headline)
            Text("在那个窗口里\(activity)。点「回到主窗口\(activity)」，或做到不能放进窗口的题时，会回到这里。")
                .foregroundStyle(.secondary)
            HStack {
                Button("调出单独窗口", systemImage: "macwindow") { window.activate(openWindow: openWindow) }
                    .buttonStyle(.borderedProminent)
                Button("回到这里\(activity)", systemImage: "arrow.uturn.backward") { window.takeBack() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .draftTappable()
        }
        .onAppear(perform: claim)
    }
}

/// 学习页、复习页的主观题：可以转到单独窗口作答，转过去后这里显示占位
struct DetachableSubjectiveCard: View {
    let pack: StudyPack
    let question: SubjectiveQuestion
    let sectionID: String
    var mode: SubjectiveCard.Mode = .study
    var nextLabel: String
    var onAssessed: (() -> Void)? = nil
    /// 复习页：做完题目下方的 AI 改编可以直接下一题
    var variantAdvances = false
    var onNext: () -> Void

    @Environment(\.openWindow) private var openWindow
    /// 两个窗口共用同一个作答流程：同一次作答（复习页打开已自评的题会另开新的作答）、没提交的自评表单
    @State private var session: SubjectiveAttemptSession
    /// 两个窗口共用题目下方展开的 AI 改编：转过去、转回来都接着做这道改编题
    @State private var variantSlot = SubjectiveCard.VariantSlot()
    private let window = SubjectiveWindow.shared

    private var place: String { mode == .study ? "study" : "review" }

    init(pack: StudyPack, question: SubjectiveQuestion, sectionID: String, mode: SubjectiveCard.Mode = .study,
         nextLabel: String, onAssessed: (() -> Void)? = nil, variantAdvances: Bool = false,
         onNext: @escaping () -> Void) {
        self.pack = pack
        self.question = question
        self.sectionID = sectionID
        self.mode = mode
        self.nextLabel = nextLabel
        self.onAssessed = onAssessed
        self.variantAdvances = variantAdvances
        self.onNext = onNext
        _session = State(initialValue: SubjectiveAttemptSession(pack: pack, question: question, sectionID: sectionID,
                                                                mode: mode))
    }

    var body: some View {
        // 用 VStack 包住：换成占位时只是里面换了内容，离开这道题时才收起改编
        VStack(spacing: 0) {
            if window.continuing || window.job?.matches(packID: pack.id, questionID: question.id, place: place) == true {
                DetachedPlaceholder(title: "第 \(question.num) 题") { window.claim(job) }
            } else {
                SubjectiveCard(pack: pack, question: question, sectionID: sectionID, mode: mode,
                               onDetach: { window.open(job, openWindow: openWindow) },
                               session: session, variantSlot: variantSlot,
                               nextLabel: nextLabel, onAssessed: onAssessed, variantAdvances: variantAdvances,
                               onNext: onNext)
            }
        }
        .onDisappear {
            variantSlot.drop()
            session.leave()
        }
    }

    private var job: SubjectiveWindow.Job {
        SubjectiveWindow.Job(packID: pack.id, questionID: question.id, place: place,
                             title: "\(pack.title) · 第 \(question.num) 题", nextLabel: nextLabel,
                             onNext: onNext) { next in
            AnyView(SubjectiveCard(pack: pack, question: question, sectionID: sectionID, mode: mode, inkInput: false,
                                   session: session, variantSlot: variantSlot,
                                   nextLabel: nextLabel, onAssessed: onAssessed, variantAdvances: variantAdvances,
                                   onNext: next))
        }
    }
}

/// 学习页、复习页的选择题：可以转到单独窗口作答（英语阅读题不加，直接用 QuestionCard）
struct DetachableQuestionCard: View {
    let pack: StudyPack
    let question: Question
    let mode: AttemptMode
    var roundNum = 0
    var existing: AttemptRecord? = nil
    var redoRecords: [AttemptRecord] = []
    var onSubmitted: ((AttemptRecord) -> Void)? = nil
    var onAIVariant: (() -> Void)? = nil
    var writing: WritingSpec? = nil
    var shuffleOptions = false
    var nextLabel: String
    var onNext: () -> Void

    @Environment(\.openWindow) private var openWindow
    /// 两个窗口共用同一个作答流程：打乱后的选项顺序、没提交的选择、计时、刚提交的作答，转过去、转回来都不变
    @State private var session: ChoiceAttemptSession
    private let window = SubjectiveWindow.shared

    init(pack: StudyPack, question: Question, mode: AttemptMode, roundNum: Int = 0, existing: AttemptRecord? = nil,
         redoRecords: [AttemptRecord] = [], onSubmitted: ((AttemptRecord) -> Void)? = nil,
         onAIVariant: (() -> Void)? = nil, writing: WritingSpec? = nil, shuffleOptions: Bool = false,
         nextLabel: String, onNext: @escaping () -> Void) {
        self.pack = pack
        self.question = question
        self.mode = mode
        self.roundNum = roundNum
        self.existing = existing
        self.redoRecords = redoRecords
        self.onSubmitted = onSubmitted
        self.onAIVariant = onAIVariant
        self.writing = writing
        self.shuffleOptions = shuffleOptions
        self.nextLabel = nextLabel
        self.onNext = onNext
        _session = State(initialValue: QuestionCard.makeSession(pack: pack, question: question, mode: mode,
                                                                roundNum: roundNum, existing: existing, writing: writing,
                                                                shuffleOptions: shuffleOptions))
    }

    var body: some View {
        // 用 VStack 包住：换成占位时只是里面换了内容，离开这道题时才算离开（leave）
        VStack(spacing: 0) {
            if window.continuing || window.job?.matches(packID: pack.id, questionID: question.id, place: mode.rawValue) == true {
                DetachedPlaceholder(title: "第 \(question.num) 题") { window.claim(job) }
            } else {
                QuestionCard(pack: pack, question: question, mode: mode, roundNum: roundNum,
                             existing: existing, redoRecords: redoRecords,
                             onSubmitted: onSubmitted, onAIVariant: onAIVariant, writing: writing,
                             shuffleOptions: shuffleOptions, onDetach: { window.open(job, openWindow: openWindow) },
                             session: session, nextLabel: nextLabel, onNext: onNext)
            }
        }
        .onDisappear { session.leave() }
    }

    private var job: SubjectiveWindow.Job {
        SubjectiveWindow.Job(packID: pack.id, questionID: question.id, place: mode.rawValue,
                             title: "\(pack.title) · 第 \(question.num) 题", nextLabel: nextLabel,
                             onNext: onNext) { next in
            AnyView(QuestionCard(pack: pack, question: question, mode: mode, roundNum: roundNum,
                                 existing: existing, redoRecords: redoRecords,
                                 onSubmitted: onSubmitted, shuffleOptions: shuffleOptions,
                                 session: session, nextLabel: nextLabel, onNext: next))
        }
    }
}

/// AI 改编复习的主观改编题：可以转到单独窗口作答，转过去后这里显示占位。
/// 两个窗口共用同一个改编流程（同一次作答），转过去、转回来都接着做
struct DetachableSubjectiveVariantCard: View {
    let title: String
    let closeLabel: String
    var onRegenerate: (Bool) -> Void
    var onNext: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var generation: SubjectiveVariantGeneration
    private let variantID: String
    private let window = SubjectiveWindow.shared
    private static let place = "aiReview"

    init(pack: StudyPack, original: SubjectiveQuestion, sectionID: String, draftKey: String, title: String,
         closeLabel: String, prepared: (id: String, generated: QuestionVariant.SubjectiveGenerated),
         onRegenerate: @escaping (Bool) -> Void, onNext: @escaping () -> Void) {
        self.title = title
        self.closeLabel = closeLabel
        self.onRegenerate = onRegenerate
        self.onNext = onNext
        variantID = prepared.id
        _generation = State(initialValue: SubjectiveVariantGeneration(pack: pack, original: original, sectionID: sectionID,
                                                                      draftKey: draftKey, prepared: prepared))
    }

    var body: some View {
        // 用 VStack 包住：换成占位时只是里面换了内容，离开这道题时才收起
        VStack(spacing: 0) {
            if window.continuing || window.job?.matches(packID: generation.pack.id, questionID: variantID,
                                                        place: Self.place) == true {
                DetachedPlaceholder(title: "这道改编题") { window.claim(job) }
            } else {
                SubjectiveVariantCard(generation: generation, title: title, closeLabel: closeLabel, showsClose: false,
                                      requireResult: true, inkInput: true,
                                      onDetach: { window.open(job, openWindow: openWindow) },
                                      onRegenerate: onRegenerate, onClose: onNext, onFinish: onNext)
            }
        }
        .onDisappear { generation.close() }
    }

    private var job: SubjectiveWindow.Job {
        let generation = generation, onNext = onNext, onRegenerate = onRegenerate
        let title = title, closeLabel = closeLabel
        // 窗口顶上的「下一题」：没提交自评的按预选的结论记下，和卡片里的「下一题」一样
        return SubjectiveWindow.Job(packID: generation.pack.id, questionID: variantID, place: Self.place,
                                    title: "\(generation.pack.title) · \(title)", nextLabel: closeLabel,
                                    onNext: {
                                        generation.session?.finishVariant(autoAssess: true)
                                        onNext()
                                    }) { next in
            AnyView(SubjectiveVariantCard(generation: generation, title: title, closeLabel: closeLabel, showsClose: false,
                                          requireResult: true, inkInput: false,
                                          onRegenerate: { useBackup in
                                              // 重新改编出的是另一道题：回到主窗口做
                                              SubjectiveWindow.shared.takeBack()
                                              onRegenerate(useBackup)
                                          },
                                          onClose: next, onFinish: next))
        }
    }
}

/// 学习页某一轮的讲解：可以转到单独窗口看，转过去后这里显示占位
struct DetachableLecture: View {
    let section: SectionFile
    let startLabel: String
    let onStart: () -> Void

    @Environment(\.openWindow) private var openWindow
    /// 两个窗口共用同一份讲解：正在生成的接着生成，追问也还在
    @State private var session: LectureSession
    private let window = SubjectiveWindow.shared

    init(pack: StudyPack, section: SectionFile, round: Round, startLabel: String, onStart: @escaping () -> Void) {
        self.section = section
        self.startLabel = startLabel
        self.onStart = onStart
        _session = State(initialValue: LectureSession(pack: pack, section: section, round: round))
    }

    /// 和题目的 questionID 区分开
    private var itemID: String { "lecture|\(section.section.id)|round\(session.round.num)" }

    var body: some View {
        if window.continuing || window.job?.matches(packID: session.pack.id, questionID: itemID, place: "study") == true {
            DetachedPlaceholder(title: "本轮讲解", activity: "看讲解") { window.claim(job) }
        } else {
            RoundLectureView(session: session, onDetach: { window.open(job, openWindow: openWindow) },
                             startLabel: startLabel, onStart: onStart)
        }
    }

    private var job: SubjectiveWindow.Job {
        let round = session.round
        let topic = round.displayTitle(chunkTitles: session.chunks.map(\.title))
        return SubjectiveWindow.Job(packID: session.pack.id, questionID: itemID, place: "study",
                                    title: "\(session.pack.title) · \(topic)", activity: "看讲解",
                                    nextLabel: startLabel, onNext: onStart) { next in
            AnyView(RoundLectureView(session: session, startLabel: startLabel, onStart: next))
        }
    }
}

/// 单独作答窗口的内容
struct SubjectiveWindowView: View {
    private let window = SubjectiveWindow.shared
    @AppStorage(SubjectiveWindow.companionKey) private var opensCompanion = true
    /// GoodNotes 区占窗口高度的比例，按 GoodNotes 摆的位置拖动调整
    @AppStorage("subjectiveWindow.companionFraction") private var companionFraction = 0.5
    /// 临时收起 GoodNotes 区，内容铺满窗口
    @State private var expanded = false
    /// 窗口高度（含安全区），GoodNotes 区按它和屏幕对齐
    @State private var windowHeight: CGFloat = 0

    private var showsZone: Bool { opensCompanion && !expanded }

    var body: some View {
        NavigationStack {
            Group {
                if let job = window.job {
                    VStack(spacing: 0) {
                        // 不要导航栏：窗口常被分屏压得很矮，导航栏会挡掉一行多题目。
                        // 按钮放在内容最上面一行，往下滚就跟着滚走
                        ScrollView {
                            VStack(spacing: 12) {
                                topButtons(job)
                                job.content { window.next() }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                            .frame(maxWidth: 900)
                            .frame(maxWidth: .infinity)
                        }
                        // 在这里作答时主窗口被盖住，休息提醒和状态询问也显示在这里（在 GoodNotes 区上方）
                        .stateCheckBanner()
                        if showsZone {
                            CompanionZone(fraction: $companionFraction, windowHeight: windowHeight) {
                                window.returnToCompanion()
                            }
                            .frame(height: windowHeight * companionFraction)
                        }
                    }
                    .ignoresSafeArea(.all, edges: showsZone ? .bottom : [])
                    .ignoresSafeArea(.keyboard)
                    .id(job.id)
                    .safeAreaInset(edge: .top) {
                        if let error = window.companionError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.bar)
                        }
                    }
                    .navigationTitle(job.title)
                    .toolbar(.hidden, for: .navigationBar)
                } else {
                    ContentUnavailableView("没有正在作答的题", systemImage: "rectangle.split.1x2",
                                           description: Text("在学习页或复习页的题目上点「单独窗口作答」，或在讲解上点「单独窗口」。点「回到主窗口」关掉这个窗口。"))
                        .toolbar {
                            Button("回到主窗口", systemImage: "arrow.uturn.backward") { window.takeBack() }
                        }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
        }
        .background(WindowReader { window.registerWindow($0?.windowScene) })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in window.logResize() }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom
        } action: { windowHeight = $0 }
    }
}

extension SubjectiveWindowView {
    /// 内容最上面一行：左边「展开」，右边「回到主窗口」和「下一题」
    private func topButtons(_ job: SubjectiveWindow.Job) -> some View {
        HStack(spacing: 10) {
            if opensCompanion {
                Button(expanded ? "留出 GoodNotes 区" : "展开",
                       systemImage: expanded ? "rectangle.split.1x2" : "rectangle") {
                    expanded.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }
            Spacer()
            Button("回到主窗口\(job.activity)", systemImage: "arrow.uturn.backward") { window.takeBack() }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            Button(job.nextLabel) { window.next() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// 单独作答窗口下方的 GoodNotes 区：平时被摆在下面的 GoodNotes 盖着，
/// 窗口被点到前面时露出来，点一下把 GoodNotes 调回来；顶上的横条可以拖动，对齐 GoodNotes 的上边
private struct CompanionZone: View {
    @Binding var fraction: Double
    let windowHeight: CGFloat
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.secondary)
                .frame(width: 60, height: 6)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(.bar)
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                    guard windowHeight > 0 else { return }
                    fraction = min(0.8, max(0.2, 1 - value.location.y / windowHeight))
                })
            VStack(spacing: 10) {
                Image(systemName: "hand.tap").font(.largeTitle)
                Text("点这里回到 GoodNotes").font(.title3.weight(.semibold))
                Text("拖动上面的横条，对齐 GoodNotes 窗口的上边；要在这个窗口里多看一会儿，点左上角「展开」。")
                    .font(.callout).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }
}

/// 取得视图所在的 UIWindow
struct WindowReader: UIViewRepresentable {
    let onWindow: (UIWindow?) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onWindow = onWindow
        return v
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onWindow: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let w = window
            DispatchQueue.main.async { [onWindow] in onWindow?(w) }
        }
    }
}
