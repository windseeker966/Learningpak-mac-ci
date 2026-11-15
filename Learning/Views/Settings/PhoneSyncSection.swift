import SwiftUI

/// 设置页「手机复习」：填手机复习 App 的配对密钥、手机地址，看同步状态（流程见 PhoneSyncSession）
struct PhoneSyncSection: View {
    @Environment(PhoneSyncSession.self) private var phone
    @State private var secretInput = ""
    @State private var secretInvalid = false

    var body: some View {
        @Bindable var phone = phone
        Section {
            if phone.paired {
                Button(phone.busy ? "正在同步…" : "立即同步", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await phone.syncNow() }
                }
                .disabled(phone.busy)
                if let last = phone.lastSuccess {
                    LabeledContent("上次同步", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let summary = phone.lastSummary {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                if phone.viaRelay {
                    LabeledContent("连接方式", value: "中转服务器（局域网里没找到手机）")
                } else if let host = phone.host {
                    LabeledContent("手机地址", value: host)
                }
                Button("取消配对", role: .destructive) { phone.unpair() }
            } else {
                HStack {
                    TextField("配对密钥，如 ABCD-EFGH-IJKL-MNOP", text: $secretInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit(pair)
                    Button("配对", action: pair).disabled(secretInput.isEmpty)
                }
                if secretInvalid {
                    Text("密钥是 16 个字母或数字（2–7），在手机复习 App 的设置里能看到").font(.callout).foregroundStyle(.red)
                }
            }
            TextField("手机地址（找不到手机时才用，如 192.168.80.148）", text: $phone.manualHost)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
            TextField("中转服务器（默认 \(PhoneRelay.defaultAddress)）", text: $phone.relayAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let error = phone.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        } header: {
            Text("手机复习")
        } footer: {
            Text("手机上的复习 App 能做今天的选择题、填空题和背单词。iPad 打开时自动和手机同步：把手机上的作答取回来计入复习安排，再把还没做的题推给手机。在同一个 Wi-Fi 或连着手机热点时直接连手机；不在一个网络时经中转服务器（内容用配对密钥加密，服务器看不到），手机每 2 分钟去收发一次。")
        }
    }

    private func pair() {
        secretInvalid = !phone.pair(secretInput)
        if !secretInvalid { secretInput = "" }
    }
}
