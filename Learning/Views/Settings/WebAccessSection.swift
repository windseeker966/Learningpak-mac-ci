import SwiftUI

/// 设置页「内置浏览器」：自己加的查资料网站（名单和规则见 WebAccess）
struct WebAccessSection: View {
    @AppStorage(WebReaderView.extraDomainsKey) private var extraText = ""
    @State private var input = ""
    @State private var invalid = false

    private var domains: [String] { extraText.split(separator: "\n").map(String.init) }

    var body: some View {
        Section {
            ForEach(domains, id: \.self) { Text($0) }
                .onDelete { offsets in
                    var list = domains
                    list.remove(atOffsets: offsets)
                    extraText = list.joined(separator: "\n")
                }
            HStack {
                TextField("加一个查资料的网站，如 fedex.com", text: $input)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button("加入", action: add).disabled(input.isEmpty)
            }
            if invalid {
                Text("不像网址，或者是论坛、视频网站（这些在 iPad 上加不进来）").font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("内置浏览器")
        } footer: {
            Text("内置浏览器能打开英文阅读（x、reddit、英文新闻）和查资料的网站（搜索、AI、词典、文档、学校）；论坛和视频网站在 iPad 上打不开，只在手机上看。名单外的查资料网站在这里加，左滑删除。iPad 上的 Chrome、Safari 用系统的屏幕使用时间挡着。")
        }
    }

    private func add() {
        guard let domain = WebAccess.domain(fromInput: input) else {
            invalid = true
            return
        }
        invalid = false
        input = ""
        if !domains.contains(domain) { extraText = (domains + [domain]).joined(separator: "\n") }
    }
}
