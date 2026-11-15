import Foundation

// 不访问真实 UU 或显示器，只替代 monitor 默认依赖。
enum UUReader {
    static var isTrusted: Bool { false }
    static func readControllers() -> [String]? { nil }
}
enum Log { static func info(_ message: String) {} }

@main struct MonitorTests {
    static func main() {
        // 用例 1：AX 极端卡顿（3 秒）不阻塞主线程，不并发堆积，过期快照被拒绝。
        let lock = NSLock()
        var reads = 0
        var overlay = true
        var connects = 0
        var disconnects = 0
        var pulses = 0
        let monitor = UUMonitor(trusted: { true }, readControllers: {
            lock.lock(); reads += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 3)
            return ["stale controller"]
        }, hasOverlay: { overlay })
        monitor.onConnect = { connects += 1 }
        monitor.onDisconnect = { disconnects += 1 }
        monitor.start()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in pulses += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        precondition(connects == 1, "覆盖窗口检测不能等待 AX 返回")
        overlay = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.9))
        precondition(disconnects == 1, "AX 阻塞时仍应按覆盖窗口缺席触发断开")
        lock.lock(); let count = reads; lock.unlock()
        precondition(count == 1, "AX 读取不能堆积或并发")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        precondition(connects == 1, "过期的 AX 结果不能重新触发连接")
        precondition(pulses >= 30, "AX 读取不能阻塞主线程")
        heartbeat.invalidate()
        monitor.stop()

        // 用例 2：1.6 秒慢 AX + 无覆盖窗口（模拟 Android/Win11）持续期间绝不能断线重连抖动。
        var slowControllers: [String]? = ["vivo X Fold6"]
        var slowConnects = 0
        var slowDisconnects = 0
        var lastUpdated: [String]?
        let slowMonitor = UUMonitor(trusted: { true }, readControllers: {
            lock.lock(); let current = slowControllers; lock.unlock()
            Thread.sleep(forTimeInterval: 1.6)
            return current
        }, hasOverlay: { false })
        slowMonitor.onConnect = { slowConnects += 1 }
        slowMonitor.onDisconnect = { slowDisconnects += 1 }
        slowMonitor.onControllersUpdate = { lastUpdated = $0 }
        slowMonitor.start()

        RunLoop.main.run(until: Date().addingTimeInterval(5.2))
        precondition(slowConnects == 1, "1.6s 慢 AX 不应反复触发重连，实际 slowConnects=\(slowConnects)")
        precondition(slowDisconnects == 0, "1.6s 慢 AX 期间不应误判断开，实际 slowDisconnects=\(slowDisconnects)")
        precondition(slowMonitor.currentController == "vivo X Fold6", "应保留当前控制端名称")
        precondition(lastUpdated == ["vivo X Fold6"], "onControllersUpdate 应送出控制端")

        // 真正断开后，1.5s 防抖期满应正确触发一次断开
        lock.lock(); slowControllers = []; lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        precondition(slowDisconnects == 1, "真实断开后应触发一次 disconnect，实际 slowDisconnects=\(slowDisconnects)")
        precondition(slowConnects == 1, "断开后不应再次触发 connect")
        precondition(slowMonitor.currentController == nil, "断开后应清空 currentController")
        slowMonitor.stop()

        print("PASS: blocked AX responsive + stale rejected + 1.6s slow-AX no-flap")
    }
}
