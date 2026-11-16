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

        // 用例 3：三档自适应节流 + overlay 零等待唤醒 + 稳定会话降频 + 断开防抖 + onTrustChange 回调
        var adaptiveOverlay = false
        var adaptiveTrust = true
        var adaptiveReads = 0
        var adaptiveControllers: [String]? = []
        var adaptiveConnects = 0
        var adaptiveDisconnects = 0
        var trustEvents: [Bool] = []

        let adaptiveMonitor = UUMonitor(
            trusted: { adaptiveTrust },
            readControllers: {
                lock.lock(); adaptiveReads += 1; let c = adaptiveControllers; lock.unlock()
                return c
            },
            hasOverlay: { adaptiveOverlay }
        )
        adaptiveMonitor.onConnect = { adaptiveConnects += 1 }
        adaptiveMonitor.onDisconnect = { adaptiveDisconnects += 1 }
        adaptiveMonitor.onTrustChange = { trustEvents.append($0) }
        adaptiveMonitor.start()

        // 空闲且无 overlay：首拍立即读取 1 次，之后 3.6 秒内不得每秒轮询
        RunLoop.main.run(until: Date().addingTimeInterval(3.6))
        lock.lock(); let idleReads = adaptiveReads; lock.unlock()
        precondition(idleReads <= 2, "空闲时不应每秒刷 AX，实际 idleReads=\(idleReads)")
        precondition(trustEvents == [true], "启动首拍应回调一次权限状态")

        // overlay 从 false 变为 true：下一拍立即唤醒 AX 读取，无需等待 5 秒空闲间隔
        lock.lock()
        adaptiveOverlay = true
        adaptiveControllers = ["iPad Air"]
        adaptiveReads = 0
        lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        lock.lock(); let wakeReads = adaptiveReads; lock.unlock()
        precondition(wakeReads >= 1, "overlay 出现后应立即唤醒 AX 读取")
        precondition(adaptiveMonitor.connected && adaptiveConnects == 2, "overlay 出现并识别控制端应触发连入与控制端就绪事件，实际 adaptiveConnects=\(adaptiveConnects)")
        precondition(adaptiveMonitor.currentController == "iPad Air", "应立即识别出控制端名称")

        // 稳定已识别的 overlay 会话期间：进入低频档位，接下来 3.5 秒内保持控制端且不再频繁读 AX
        lock.lock(); adaptiveReads = 0; lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        lock.lock(); let stableReads = adaptiveReads; lock.unlock()
        precondition(stableReads <= 1, "稳定会话期间应降频读 AX，实际 stableReads=\(stableReads)")
        precondition(adaptiveDisconnects == 0, "稳定会话期间不应断开")

        // overlay 消失后应失效缓存并在 2 秒内干净断开
        lock.lock()
        adaptiveOverlay = false
        adaptiveControllers = []
        lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        precondition(adaptiveDisconnects == 1, "overlay 消失后应在 2 秒内干净断开，实际 disconnects=\(adaptiveDisconnects)")

        // 权限状态翻转回调
        adaptiveTrust = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        adaptiveTrust = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        precondition(trustEvents == [true, false, true], "权限状态变化应实时回调 onTrustChange，实际 \(trustEvents)")
        adaptiveMonitor.stop()

        print("PASS: blocked AX responsive + stale rejected + 1.6s slow-AX no-flap + adaptive polling & trust change")
    }
}
