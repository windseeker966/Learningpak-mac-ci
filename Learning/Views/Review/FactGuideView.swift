import SwiftUI

/// 计算测速的背诵表和方法：怎么背，进位加法和对应的退位减法、口诀、倍数表，以及还没背熟时的正确算法。
/// 内容和手机复习 App 的 assets/web/guide.js 一致，改一边要同步另一边
struct FactGuideView: View {
    var body: some View {
        List {
            Section {
                tip("背熟就是看到就知道，不用凑十、不用顺着口诀往下数。乘法口诀你现在 0.3 秒就能答出，就是背熟的样子。")
                tip("加减一起念出声，三个数当成一组：「六加七，十三；十三减七，六；十三减六，七」。")
                tip("练的时候不要算：1 秒内想不出来，就看答案、把整个式子念一遍，过一会儿再考。每次靠凑十算出来，练的是凑十，不是记忆。")
                tip("每天测一轮：答错、答得慢的会多出现。先背下面标出的最慢的几个：13−7、14−6、12−5、15−6、16−7、13−8，除数是 6、7、8 的除法。")
            } header: {
                Text("怎么背")
            }

            Section {
                ForEach(ArithmeticFacts.additionBySum, id: \.sum) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(row.sum)").bold().frame(width: 32, alignment: .leading)
                            Text(row.pairs.map { "\($0.0)+\($0.1)" }.joined(separator: "　"))
                        }
                        Text(subtractions(row.sum, row.pairs).joined(separator: "　"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 40)
                    }
                    .monospacedDigit()
                }
            } header: {
                Text("进位加法 20 组 · 对应的退位减法")
            } footer: {
                Text("交换顺序算同一组（6+7 和 7+6）。每组加法管着两个减法：知道 6+7=13，就知道 13−7=6、13−6=7。")
            }

            Section {
                ForEach(2...9, id: \.self) { b in
                    Text((2...b).map { "\(Self.koujue($0, b))" }.joined(separator: "　"))
                        .font(.callout)
                }
            } header: {
                Text("乘法口诀（表内除法就是倒过来用）")
            } footer: {
                Text("看到积就想起那一句：56 →「七八五十六」，56÷7=8、56÷8=7。比 20 大的积，除了 24（三八、四六）和 36（四九、六六），每个只在一句口诀里。")
            }

            Section {
                ForEach(2...9, id: \.self) { d in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(d)").bold().frame(width: 32, alignment: .leading)
                        Text((1...9).map { String(d * $0) }.joined(separator: "  "))
                    }
                    .monospacedDigit()
                }
            } header: {
                Text("倍数表（带余除法）")
            } footer: {
                Text("看被除数夹在哪两个倍数之间，取下面那个：50÷7，50 在 49 和 56 之间，商 7，余数 50−49=1。余数一定比除数小。6、7、8、9 的倍数要背熟。")
            }

            Section {
                method("退位减法（还没背熟时）", "想加算减：13−7 想成「7 加几得 13」→ 6。")
                method("两位数减法", "两个数同时加同一个数，让减数变成整十，差不变，也不用退位：92−39 = 93−40 = 53；73−48 = 75−50 = 25；125−68 = 127−70 = 57。")
                method("两位数加法", "只拆一个数，另一个保持完整：67+45 = 67+40+5 = 107+5 = 112。或者凑整：67+45 = 70+42 = 112。不要两个数都拆（60+40 和 7+5），最后合并时进位容易算两次。")
                method("结果是三位数", "算完整个结果再写，或者从个位写起，不要边算边从左往右写。写完估一下：26×8 ≈ 25×8 = 200，所以 228 不对。")
                method("两位数乘一位数", "拆开再加：38×7 = 30×7 + 8×7 = 210 + 56 = 266；接近整十的用减：29×3 = 30×3 − 3 = 87。")
                method("试商（除数是两位数）", "把除数看成整十来估商：162÷27，27 看成 30，16÷3 得 5。除数往大凑（27→30），估出的商可能偏小：减完看余数，余数不比除数小就加 1（162−135=27，商改成 6）。除数往小凑（63→60），估出的商可能偏大：乘出来比被除数大就减 1。")
                method("小数加减", "对齐小数点，位数不够补 0：7.8−3.95 写成 7.80−3.95。借位、进位写上小点。能心算的就心算。")
                method("小数乘法", "末位对齐，先当整数乘，最后数两个因数一共几位小数：0.36×2.5 → 36×25 = 900 → 三位小数 → 0.900 = 0.9。")
                method("小数除法", "先把除数变成整数（被除数一起乘 10、100）；除不尽就在余数后面补 0 接着除，不写「余」：0.63÷1.4 = 6.3÷14 = 0.45。最简分数的分母只有因数 2 和 5 时一定除得尽。")
                method("高数里遇到小数", "直接化成分数算：0.63÷1.4 = 63/140 = 9/20；0.36×2.5 = 36/100 × 5/2 = 9/10。")
            } header: {
                Text("正确的算法")
            }
        }
        .navigationTitle("背诵表和方法")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tip(_ text: String) -> some View {
        Text(text).font(.callout)
    }

    private func method(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.callout)
        }
        .padding(.vertical, 2)
    }

    /// 和为 sum 的一组加法对应的减法，按减数从小到大
    private func subtractions(_ sum: Int, _ pairs: [(Int, Int)]) -> [String] {
        Set(pairs.flatMap { [$0.0, $0.1] }).sorted().map { "\(sum)−\($0)=\(sum - $0)" }
    }

    private static let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    /// 口诀：「二三得六」「三四十二」「二五一十」「七八五十六」
    static func koujue(_ a: Int, _ b: Int) -> String {
        let p = a * b, head = digits[a] + digits[b]
        if p < 10 { return head + "得" + digits[p] }
        if p == 10 { return head + "一十" }
        let tens = p / 10, ones = p % 10
        return head + (tens == 1 ? "" : digits[tens]) + "十" + digits[ones]
    }
}
