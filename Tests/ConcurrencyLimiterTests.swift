import Foundation

// 并发闸门：
// swiftc -swift-version 6 -parse-as-library -default-isolation MainActor Learning/AI/ConcurrencyLimiter.swift Tests/ConcurrencyLimiterTests.swift -o /tmp/limiter-tests
// /tmp/limiter-tests
@main
private enum ConcurrencyLimiterTests {
    static var failures = 0

    static func check(_ ok: Bool, _ message: String) {
        if !ok {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        await limitsConcurrency()
        await firstComeFirstServed()
        await cancelWhileWaiting()
        await cancelBeforeAcquire()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        if failures > 0 { exit(1) }
    }

    /// 10 个任务、上限 3：同时进行的不超过 3 个，全部都能做完，做完后空位全部归还
    static func limitsConcurrency() async {
        let limiter = ConcurrencyLimiter(limit: 3)
        var current = 0, peak = 0, done = 0
        let tasks = (0..<10).map { _ in
            Task {
                guard await limiter.acquire() else { return }
                current += 1
                peak = max(peak, current)
                try? await Task.sleep(for: .milliseconds(20))
                current -= 1
                done += 1
                limiter.release()
            }
        }
        for t in tasks { await t.value }
        check(peak == 3, "同时进行的最多应为 3，实际 \(peak)")
        check(done == 10, "应全部做完，实际 \(done)")
        check(limiter.activeCount == 0, "做完后应没有占用的空位，实际 \(limiter.activeCount)")
    }

    /// 排队的按先后顺序拿到空位
    static func firstComeFirstServed() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        _ = await limiter.acquire()
        var order: [Int] = []
        var tasks: [Task<Void, Never>] = []
        for i in 0..<4 {
            tasks.append(Task {
                guard await limiter.acquire() else { return }
                order.append(i)
                limiter.release()
            })
            // 让这个任务先排进队列，再建下一个
            try? await Task.sleep(for: .milliseconds(10))
        }
        limiter.release()
        for t in tasks { await t.value }
        check(order == [0, 1, 2, 3], "应按排队顺序，实际 \(order)")
        check(limiter.activeCount == 0, "做完后应没有占用的空位，实际 \(limiter.activeCount)")
    }

    /// 排队时取消：返回 false、不占空位，后面排队的照常拿到
    static func cancelWhileWaiting() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        _ = await limiter.acquire()
        let cancelled = Task { await limiter.acquire() }
        try? await Task.sleep(for: .milliseconds(10))
        var gotSlot = false
        let next = Task {
            guard await limiter.acquire() else { return }
            gotSlot = true
            limiter.release()
        }
        try? await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        check(await cancelled.value == false, "排队时取消应返回 false")
        limiter.release()
        await next.value
        check(gotSlot, "取消的任务之后排队的应拿到空位")
        check(limiter.activeCount == 0, "做完后应没有占用的空位，实际 \(limiter.activeCount)")
    }

    /// 已取消的任务直接返回 false，不占空位
    static func cancelBeforeAcquire() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        let t = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await limiter.acquire()
        }
        check(await t.value == false, "已取消时应返回 false")
        check(limiter.activeCount == 0, "已取消时不应占用空位，实际 \(limiter.activeCount)")
    }
}
