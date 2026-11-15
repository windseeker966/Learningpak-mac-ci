import Foundation

/// 限制同时进行的任务数：没有空位时排队，先到先得。
/// 用法：`guard await limiter.acquire() else { 已取消 }`，做完后 `limiter.release()`。
final class ConcurrencyLimiter {
    let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) { self.limit = limit }

    /// 正在进行的任务数
    var activeCount: Int { running }

    /// 取得一个空位；排队时任务被取消则返回 false（不占空位，不用 release）
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // 排队前已被取消时 onCancel 找不到它，这里直接返回
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    /// 让出空位：有排队的直接交给最早排队的
    func release() {
        if waiters.isEmpty {
            running = max(running - 1, 0)
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(returning: false)
    }
}
