// 虚拟屏与物理屏的显示拓扑管理：目标状态 + 逐步收敛
// 调用方只声明「应该是什么样」（desired），执行器一次只做一步拓扑变化，每步之后等待系统稳定再做下一步。
// 关键保障：
//   1. 虚拟屏使用确定性 FNV-1a serialNum，避免每次建屏在 /Library/ColorSync/Profiles/Displays/ 生成新 ICC 文件
//   2. 只对真实物理屏（排除 0x5555 虚拟屏与 'unkn'/'virt' 无头占位屏）记录完整分辨率与原点，成功还原后才删除 session.json
//   3. 虚拟屏释放前确认已上线且存活 ≥ 2.5 秒；断开收尾全程持有防休眠断言，休眠中延后还原
//   4. 物理屏恢复连续失败 3 次时先释放虚拟屏再重试，避免无头/拔屏死锁永久卡住虚拟屏
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

struct SavedDisplayState: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Int?
    var height: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var refreshRate: Double?

    func matches(_ id: CGDirectDisplayID) -> Bool {
        let origin = CGDisplayBounds(id).origin
        if abs(origin.x - x) > 1.0 || abs(origin.y - y) > 1.0 { return false }
        if let w = width, let h = height, let mode = CGDisplayCopyDisplayMode(id) {
            if mode.width != w || mode.height != h { return false }
            if let pw = pixelWidth, let ph = pixelHeight,
               (mode.pixelWidth != pw || mode.pixelHeight != ph) {
                return false
            }
        }
        return true
    }
}

final class DisplayManager {
    static let vendorID: UInt32 = PhysicalDisplays.virtualVendorID

    // 目标状态
    private var desired: DeviceConfig?
    private var shutdownCompletion: (() -> Void)?
    /// 是否应禁用物理屏（由 Coordinator 按连接态、设置决定）
    var shouldDisablePhysical: () -> Bool = { false }
    /// 用户手动恢复后，本次连接内不再禁用
    private var physicalOverride = false

    // 实际状态
    private var vd: CGVirtualDisplay?
    private(set) var current: DeviceConfig?
    private var mainSet = false
    /// 换设备时的旧屏，等新屏成为主屏后释放
    private var retiring: [CGVirtualDisplay] = []
    /// 配置失败的虚拟屏，稳定后再释放（立即释放曾触发 WindowServer 崩溃）
    private var broken: [CGVirtualDisplay] = []
    /// 同一配置创建失败后不再重试，直到目标变化
    private var failedCfg: DeviceConfig?
    /// 建屏前各真实物理屏的完整状态（分辨率 + 原点），用于还原
    private var savedStates: [CGDirectDisplayID: SavedDisplayState] = [:]

    // 执行器与防呆状态
    private var busy = false
    /// 启动时先把残留状态恢复干净，期间忽略目标设备
    private var recovering = false
    private var waitOnlineTries = 0
    private var bornAt: [CGDirectDisplayID: Date] = [:]
    private var serialByDisplayID: [CGDirectDisplayID: UInt32] = [:]
    private var releaseWaitStart: Date?
    private var restoreFailCount = 0
    private var stateRestoreFailCount = 0
    private var stateRestoreGaveUp = false
    private var sleepWaitLogged = false
    private let sleepGuard = DisplaySleepGuard()
    /// WindowServer 显示配置无响应（事务超时）：停止建屏/删屏/改布局，可由用户手动 retryRecovery 解除
    private(set) var wedged = false
    static let minLifetime: TimeInterval = 2.5
    private let cgQueue = DispatchQueue(label: "uudisplay.display-config")

    private static let markerURL = ConfigStore.dir.appendingPathComponent("session.json")

    var isActive: Bool { vd != nil }
    var physicalOff: Bool { PhysicalDisplays.pending != nil }
    var hasSavedStates: Bool { !savedStates.isEmpty || FileManager.default.fileExists(atPath: DisplayManager.markerURL.path) }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        PhysicalDisplays.isVirtual(id)
    }

    /// 确定性 FNV-1a 32 位序列号：同一设备名 + 像素规格 + HiDPI 始终映射同一显示器身份，避免 ColorSync ICC 无限堆积
    static func stableSerial(name: String, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool, salt: UInt32 = 0) -> UInt32 {
        DeviceConfig.stableSerial(name: name, pixelWidth: pixelWidth, pixelHeight: pixelHeight, hiDPI: hiDPI, salt: salt)
    }

    private static func same(_ a: DeviceConfig?, _ b: DeviceConfig?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let ea = a.effectivePixels
        let eb = b.effectivePixels
        return ea.width == eb.width && ea.height == eb.height && a.hiDPI == b.hiDPI
    }

    /// 已是同规格虚拟屏则不动
    func matches(_ cfg: DeviceConfig) -> Bool {
        DisplayManager.same(desired, cfg) && vd != nil
    }

    // MARK: - 对外接口：只改目标状态

    func create(_ cfg: DeviceConfig) {
        if !DisplayManager.same(desired, cfg) { failedCfg = nil }
        desired = cfg
        stateRestoreFailCount = 0
        stateRestoreGaveUp = false
        sleepWaitLogged = false
        kick()
    }

    func remove(completion: (() -> Void)? = nil) {
        if desired != nil || vd != nil || !retiring.isEmpty {
            sleepGuard.beginClosing()
        }
        desired = nil
        failedCfg = nil
        physicalOverride = false
        restoreFailCount = 0
        stateRestoreFailCount = 0
        stateRestoreGaveUp = false
        sleepWaitLogged = false
        if let completion { shutdownCompletion = completion }
        kick()
    }

    func disablePhysicalIfNeeded() { kick() }

    /// 快捷键 / 菜单 / 关闭开关：立即恢复物理屏，虚拟屏保留
    func restorePhysicalNow(override: Bool = true) {
        if override { physicalOverride = true }
        restoreFailCount = 0
        kick()
    }

    /// 从 wedged 或还原失败中手动恢复重试
    func retryRecovery() {
        wedged = false
        failedCfg = nil
        restoreFailCount = 0
        stateRestoreFailCount = 0
        stateRestoreGaveUp = false
        sleepWaitLogged = false
        if physicalOff || !savedStates.isEmpty {
            recovering = true
        }
        kick()
    }

    /// 清理本地残留恢复记录（用于诊断页用户手动重置）
    func clearResidualMarkers() {
        PhysicalDisplays.clearMarker()
        savedStates = [:]
        try? FileManager.default.removeItem(at: DisplayManager.markerURL)
        wedged = false
        recovering = false
        restoreFailCount = 0
        stateRestoreFailCount = 0
        stateRestoreGaveUp = false
        Log.info("已手动清理残留恢复记录并重置保护状态")
    }

    /// 启动时：读回上次未收尾的布局记录（兼容旧 [x, y] 与新 SavedDisplayState）；残留的物理屏禁用记录由执行器按「目标=无」自动恢复
    func recoverIfNeeded() {
        if let data = try? Data(contentsOf: DisplayManager.markerURL) {
            if let dict = try? JSONDecoder().decode([String: SavedDisplayState].self, from: data) {
                for (k, v) in dict {
                    if let id = UInt32(k), !PhysicalDisplays.isVirtual(id), !PhysicalDisplays.isHeadlessPlaceholder(id) {
                        savedStates[id] = v
                    }
                }
            } else if let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] {
                for (k, v) in legacy where v.count == 2 {
                    if let id = UInt32(k), !PhysicalDisplays.isVirtual(id), !PhysicalDisplays.isHeadlessPlaceholder(id) {
                        savedStates[id] = SavedDisplayState(x: v[0], y: v[1])
                    }
                }
            }
        }
        if !savedStates.isEmpty || physicalOff {
            Log.info("发现上次未收尾的显示记录，先尝试恢复物理屏与显示器布局")
            recovering = true
        } else if FileManager.default.fileExists(atPath: DisplayManager.markerURL.path) {
            // marker 中仅含无效/无头占位屏记录，直接清理避免误触发
            try? FileManager.default.removeItem(at: DisplayManager.markerURL)
        }
        kick()
    }

    // MARK: - 执行器

    private func kick() {
        guard !busy else { return }
        step()
    }

    /// 完成一步后等待 settle 秒再评估下一步
    private func finish(settle: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            self.busy = false
            self.step()
        }
    }

    /// 在 cgQueue 执行配置事务，回到主线程后进入稳定等待；事务超时则进入保护状态
    private func runCG(settle: TimeInterval, _ work: @escaping () -> CGError, onDone: ((CGError) -> Void)? = nil) {
        busy = true
        cgQueue.async {
            let err = work()
            DispatchQueue.main.async {
                if err == .cannotComplete || err.rawValue == 1014 { self.enterWedged(err) }
                onDone?(err)
                self.finish(settle: settle)
            }
        }
    }

    private func enterWedged(_ err: CGError) {
        guard !wedged else { return }
        wedged = true
        Log.info("⛔️ WindowServer 显示配置无响应（CGError=\(err.rawValue)），暂停自动显示切换；可在菜单栏点「立即恢复所有屏幕」重试或重启 Mac")
    }

    /// 释放前确认每块屏已上线且存活足够久；最多等 8 秒
    private func readyToRelease(_ displays: [CGVirtualDisplay]) -> Bool {
        let online = Set(DisplayManager.onlineDisplays())
        let young = displays.contains { d in
            !online.contains(d.displayID) || Date().timeIntervalSince(bornAt[d.displayID] ?? .distantPast) < DisplayManager.minLifetime
        }
        guard young else { releaseWaitStart = nil; return true }
        let start = releaseWaitStart ?? Date()
        releaseWaitStart = start
        if Date().timeIntervalSince(start) > 8 { releaseWaitStart = nil; return true }
        return false
    }

    private func step() {
        guard !busy else { return }
        if wedged {
            // 保护状态：只尝试恢复物理屏，其余全部停止
            if physicalOff {
                return runCG(settle: 3.0) { PhysicalDisplays.restore(reason: "保护状态") ? .success : .failure }
            }
            sleepGuard.end()
            if let done = shutdownCompletion { shutdownCompletion = nil; done() }
            return
        }

        // 1. 配置失败的屏：稳定后释放
        if !broken.isEmpty {
            guard readyToRelease(broken) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&broken)
            return finish(settle: 1.5)
        }

        guard let want = recovering ? nil : desired else {
            // 目标=无：恢复物理屏 → 释放虚拟屏 → 还原布局与分辨率
            if physicalOff && (restoreFailCount < 3 || (vd == nil && retiring.isEmpty)) {
                return runCG(settle: 1.5, {
                    PhysicalDisplays.restore(reason: "远程结束") ? .success : .failure
                }, onDone: { err in
                    if err == .success {
                        self.restoreFailCount = 0
                    } else {
                        self.restoreFailCount += 1
                    }
                })
            }
            if vd != nil || !retiring.isEmpty {
                guard readyToRelease(retiring + [vd].compactMap { $0 }) else { busy = true; return finish(settle: 0.5) }
                busy = true
                var all = retiring + [vd].compactMap { $0 }
                retiring = []
                vd = nil
                current = nil
                mainSet = false
                release(&all)
                // 释放虚拟屏后重置一次物理屏失败计数，允许补试一次物理恢复
                if physicalOff { restoreFailCount = 0 }
                return finish(settle: 1.5)
            }
            if !savedStates.isEmpty && !stateRestoreGaveUp {
                let online = Set(DisplayManager.onlineDisplays())
                let targets = savedStates.filter {
                    online.contains($0.key) && !PhysicalDisplays.isVirtual($0.key) && !PhysicalDisplays.isHeadlessPlaceholder($0.key)
                }
                if targets.isEmpty {
                    savedStates = [:]
                    try? FileManager.default.removeItem(at: DisplayManager.markerURL)
                } else if targets.keys.contains(where: { CGDisplayIsAsleep($0) != 0 }) {
                    if !sleepWaitLogged {
                        sleepWaitLogged = true
                        Log.info("物理屏处于休眠状态，等待唤醒后再还原分辨率与布局")
                    }
                    busy = true
                    return finish(settle: 2.0)
                } else if targets.allSatisfy({ $0.value.matches($0.key) }) {
                    savedStates = [:]
                    try? FileManager.default.removeItem(at: DisplayManager.markerURL)
                    Log.info("✅ 显示器分辨率与布局已匹配，无需额外配置")
                } else {
                    sleepWaitLogged = false
                    return runCG(settle: 0.5, {
                        DisplayManager.restoreStates(targets)
                    }, onDone: { err in
                        if err == .success {
                            self.savedStates = [:]
                            self.stateRestoreFailCount = 0
                            try? FileManager.default.removeItem(at: DisplayManager.markerURL)
                        } else {
                            self.stateRestoreFailCount += 1
                            if self.stateRestoreFailCount >= 3 {
                                self.stateRestoreGaveUp = true
                                Log.info("⚠️ 还原显示器布局连续失败 3 次（保留恢复记录），可在菜单栏手动重试")
                            }
                        }
                    })
                }
            }
            if recovering {
                recovering = false
                restoreFailCount = 0
                Log.info("残留状态处理完成")
                if desired != nil { return step() }
            }
            sleepGuard.end()
            if let done = shutdownCompletion {
                shutdownCompletion = nil
                done()
            }
            return
        }

        // 目标=某设备的虚拟屏
        sleepGuard.beginSession()

        // 必须在创建虚拟屏之前捕获真实物理屏基线，否则系统可能已联动修改物理屏模式
        if savedStates.isEmpty && vd == nil {
            captureBaseline(from: DisplayManager.onlineDisplays())
        }

        if vd == nil || !DisplayManager.same(current, want) {
            guard !DisplayManager.same(failedCfg, want) else { return }
            busy = true
            if let old = vd { retiring.append(old) }
            vd = nil
            current = nil
            mainSet = false
            waitOnlineTries = 0
            if !createDisplay(want) { failedCfg = want }
            return finish(settle: 1.0)
        }

        if !mainSet, let id = vd?.displayID {
            let online = DisplayManager.onlineDisplays()
            guard online.contains(id) else {
                waitOnlineTries += 1
                if waitOnlineTries > 20 { Log.info("⚠️ 虚拟屏 5 秒内未上线"); mainSet = true }
                busy = true
                return finish(settle: 0.25)
            }
            if savedStates.isEmpty {
                captureBaseline(from: online)
            }
            mainSet = true
            // 设为主屏后等待 1.0s，留出窗口让 UURemoteServer 的 ScreenCaptureKit / AudioTap 平滑迁移
            return runCG(settle: 1.0) {
                let err = applyDisplayConfig { cfg in
                    let t = CGDisplayBounds(id).origin
                    for d in online {
                        let o = CGDisplayBounds(d).origin
                        CGConfigureDisplayOrigin(cfg, d, Int32(o.x - t.x), Int32(o.y - t.y))
                    }
                }
                Log.info(err == .success ? "✅ 虚拟屏已设为主屏" : "⚠️ 设主屏失败 CGError=\(err.rawValue)")
                return err
            }
        }

        if !retiring.isEmpty {
            guard readyToRelease(retiring) else { busy = true; return finish(settle: 0.5) }
            busy = true
            release(&retiring)
            return finish(settle: 1.5)
        }

        let wantOff = shouldDisablePhysical() && !physicalOverride
        if wantOff, !physicalOff, let id = vd?.displayID {
            let physical = PhysicalDisplays.realPhysicalDisplays(in: DisplayManager.onlineDisplays())
            if !physical.isEmpty {
                return runCG(settle: 1.5) {
                    let err = PhysicalDisplays.disable(physical)
                    Log.info(err == .success ? "✅ 已关闭物理屏 \(physical)，只保留虚拟屏 #\(id)" : "⚠️ 关闭物理屏失败 CGError=\(err.rawValue)")
                    return err
                }
            }
        }
        if !wantOff, physicalOff {
            return runCG(settle: 1.5) { PhysicalDisplays.restore(reason: "手动恢复") ? .success : .failure }
        }
    }

    // MARK: - 单步操作

    private func nextAvailableSerial(name: String, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool) -> UInt32 {
        let inUse = Set(serialByDisplayID.values)
        for salt: UInt32 in 0..<16 {
            let candidate = DisplayManager.stableSerial(name: name, pixelWidth: pixelWidth, pixelHeight: pixelHeight, hiDPI: hiDPI, salt: salt)
            if !inUse.contains(candidate) { return candidate }
        }
        return UInt32.random(in: 1...0xFFFF_FFF0)
    }

    private func createDisplay(_ cfg: DeviceConfig) -> Bool {
        let (w, h) = cfg.effectivePixels
        let primarySerial = nextAvailableSerial(name: cfg.name, pixelWidth: w, pixelHeight: h, hiDPI: cfg.hiDPI)

        func makeVirtualDisplay(serial: UInt32) -> CGVirtualDisplay? {
            let desc = CGVirtualDisplayDescriptor()
            desc.name = "UUyc companion · \(cfg.name)"  // 显示在 UU 的多显示屏列表、系统显示器设置中
            desc.maxPixelsWide = UInt32(w)
            desc.maxPixelsHigh = UInt32(h)
            desc.sizeInMillimeters = CGSize(width: Double(w) / 220 * 25.4, height: Double(h) / 220 * 25.4)
            desc.vendorID = DisplayManager.vendorID
            desc.productID = 0x0001
            desc.serialNum = serial
            return autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        }

        var usedSerial = primarySerial
        var created = makeVirtualDisplay(serial: primarySerial)
        if created == nil {
            let fallbackSerial = UInt32.random(in: 1...0xFFFF_FFF0)
            Log.info("⚠️ 使用稳定序列号创建虚拟屏返回 nil，尝试备用序列号重试")
            created = makeVirtualDisplay(serial: fallbackSerial)
            usedSerial = fallbackSerial
        }

        guard let display = created else {
            Log.info("❌ 创建虚拟屏失败（CGVirtualDisplay 返回 nil）")
            return false
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI
        let mw = cfg.hiDPI ? w / 2 : w, mh = cfg.hiDPI ? h / 2 : h
        if let mode = CGVirtualDisplayMode(width: UInt(mw), height: UInt(mh), refreshRate: 60) {
            settings.modes = [mode]
        }
        guard autoreleasepool(invoking: { display.apply(settings) }) else {
            Log.info("❌ 虚拟屏 applySettings 失败，稳定后释放")
            bornAt[display.displayID] = Date()
            serialByDisplayID[display.displayID] = usedSerial
            broken.append(display)
            return false
        }
        vd = display
        current = cfg
        bornAt[display.displayID] = Date()
        serialByDisplayID[display.displayID] = usedSerial
        Log.info("✅ 已创建虚拟屏 #\(display.displayID) \(cfg.name) \(cfg.sizeLabel)")
        return true
    }

    private func release(_ displays: inout [CGVirtualDisplay]) {
        guard !displays.isEmpty else { return }
        let ids = displays.map { "#\($0.displayID)" }.joined(separator: " ")
        for d in displays {
            bornAt.removeValue(forKey: d.displayID)
            serialByDisplayID.removeValue(forKey: d.displayID)
        }
        autoreleasepool { displays.removeAll() }
        Log.info("✅ 已移除虚拟屏 \(ids)")
    }

    private func captureBaseline(from online: [CGDirectDisplayID]) {
        let physical = PhysicalDisplays.realPhysicalDisplays(in: online)
        guard !physical.isEmpty else { return }
        var map: [CGDirectDisplayID: SavedDisplayState] = [:]
        for id in physical {
            let origin = CGDisplayBounds(id).origin
            let mode = CGDisplayCopyDisplayMode(id)
            map[id] = SavedDisplayState(
                x: Double(origin.x),
                y: Double(origin.y),
                width: mode?.width,
                height: mode?.height,
                pixelWidth: mode?.pixelWidth,
                pixelHeight: mode?.pixelHeight,
                refreshRate: mode?.refreshRate
            )
        }
        savedStates = map
        writeMarker()
    }

    private static func bestMatchingMode(for id: CGDirectDisplayID, saved: SavedDisplayState) -> CGDisplayMode? {
        guard let targetW = saved.width, let targetH = saved.height else { return nil }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let rawModes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return nil }
        let candidates = rawModes.filter { $0.width == targetW && $0.height == targetH && $0.isUsableForDesktopGUI() }
        guard !candidates.isEmpty else { return nil }
        let pixelMatched: [CGDisplayMode]
        if let pw = saved.pixelWidth, let ph = saved.pixelHeight {
            let exact = candidates.filter { $0.pixelWidth == pw && $0.pixelHeight == ph }
            pixelMatched = exact.isEmpty ? candidates : exact
        } else {
            pixelMatched = candidates
        }
        if let targetHz = saved.refreshRate, targetHz > 0 {
            return pixelMatched.min { abs($0.refreshRate - targetHz) < abs($1.refreshRate - targetHz) }
        }
        return pixelMatched.first
    }

    private static func restoreStates(_ states: [CGDirectDisplayID: SavedDisplayState]) -> CGError {
        let err = applyDisplayConfig { cfg in
            for (id, st) in states {
                if let mode = bestMatchingMode(for: id, saved: st) {
                    CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
                }
                CGConfigureDisplayOrigin(cfg, id, Int32(st.x.rounded()), Int32(st.y.rounded()))
            }
        }
        Log.info(err == .success ? "✅ 已还原显示器分辨率与布局" : "⚠️ 还原布局 CGError=\(err.rawValue)")
        return err
    }

    private func writeMarker() {
        let dict = Dictionary(uniqueKeysWithValues: savedStates.map { ("\($0.key)", $0.value) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(dict).write(to: DisplayManager.markerURL, options: .atomic)
    }
}
