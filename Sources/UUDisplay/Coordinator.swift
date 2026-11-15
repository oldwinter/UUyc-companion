// 连入/断开 → 选设备配置 → 建屏/还原
// 只处理 UU 设备列表里、且填了分辨率的设备；读不到名字或认不出就不调整，交给 UU远程 自己处理
import AppKit

final class Coordinator {
    let monitor = UUMonitor()
    let display = DisplayManager()
    private let store = ConfigStore.shared

    /// 状态变化时通知菜单栏刷新
    var onChange: (() -> Void)?

    private(set) var controllerName: String?
    private var openedUUWindow = false
    private var openingUUWindow = false
    private var swappedOrientation = false
    private var shuttingDown = false

    /// 调试：模拟连入的控制端名称（不读 UU）
    var simulatedName: String?

    var connected: Bool { monitor.connected || simulatedName != nil }

    func start() {
        display.shouldDisablePhysical = { [weak self] in self?.physicalDisableAllowed ?? false }
        display.recoverIfNeeded()
        monitor.onConnect = { [weak self] in self?.handleConnect() }
        monitor.onDisconnect = { [weak self] in self?.handleDisconnect() }
        monitor.onControllersUpdate = { [weak self] controllers in self?.handleControllersUpdate(controllers) }
        monitor.start()
        applyKeepWarmIfIdle()
    }

    /// 开关打开、处于远控会话且私有 API 可用时才关闭物理屏；待机保活（keepWarm）期间绝不熄灭物理屏
    var physicalDisableAllowed: Bool {
        connected && store.config.shouldDisablePhysical && PhysicalDisplays.available
    }

    var canSwapOrientation: Bool {
        guard display.isActive, let current = display.current else { return false }
        return current.width != current.height
    }

    var needsRecovery: Bool {
        display.physicalOff || PhysicalDisplays.pending != nil || display.hasSavedStates || display.wedged
    }

    var statusText: String {
        if display.wedged { return "⛔️ 屏幕设置无响应，请重启 Mac" }
        if store.config.paused { return "虚拟屏已暂停：连接时不做调整" }
        if !connected {
            if let c = display.current, display.isActive {
                return "待机就绪 · 虚拟屏已预备 \(c.sizeLabel)"
            }
            return "等待其它设备连接中"
        }
        let who = controllerName ?? "未知设备"
        if let c = display.current, display.isActive {
            return "\(who) 已连接 · 虚拟屏已匹配 \(c.sizeLabel)\(display.physicalOff ? " · 物理屏幕已软关闭" : "")"
        }
        return "\(who) 已连接 · 虚拟屏没有调整"
    }

    // MARK: - 事件

    func handleConnect() {
        guard !shuttingDown else { return }
        if let name = simulatedName ?? monitor.currentController {
            resolve(name)
            return
        }
        onChange?()
        guard !store.config.paused else { return }
        openUUWindowOnceIfNeeded()
    }

    func handleDisconnect() {
        controllerName = nil
        openedUUWindow = false
        openingUUWindow = false
        swappedOrientation = false

        if !shuttingDown, !store.config.paused, let warm = keepWarmConfig() {
            if display.physicalOff || PhysicalDisplays.pending != nil || display.hasSavedStates {
                display.restorePhysicalNow()
            }
            if !display.matches(warm) {
                display.create(warm)
            }
        } else {
            display.remove()
        }
        onChange?()
    }

    private func handleControllersUpdate(_ controllers: [String]?) {
        guard !shuttingDown, connected, !store.config.paused, simulatedName == nil else { return }
        if let name = controllers?.first ?? monitor.currentController {
            resolve(name)
        } else if controllers == nil, controllerName == nil {
            openUUWindowOnceIfNeeded()
        }
    }

    private func openUUWindowOnceIfNeeded() {
        guard !openedUUWindow, !openingUUWindow, UUReader.isTrusted, simulatedName == nil else { return }
        openingUUWindow = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasWindow = UUReader.hasMainWindow
            var didTry = false
            if !hasWindow {
                Log.info("UU 主窗口未打开，异步尝试打开以读取控制端名称")
                UUReader.showMainWindow()
                didTry = true
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.openingUUWindow = false
                if didTry { self.openedUUWindow = true }
            }
        }
    }

    private func resolve(_ name: String) {
        guard !store.config.paused else { return }
        if controllerName != name {
            swappedOrientation = false
            controllerName = name
            Log.info("控制端：\(name)")
        }
        let cfg: DeviceConfig?
        if let known = store.device(named: name) {
            cfg = known
        } else if simulatedName != nil {
            // 调试模拟：未配置的名称用固定测试尺寸
            cfg = DeviceConfig(name: name, kind: .tablet, width: 2360, height: 1640)
        } else {
            cfg = nil
            if !display.isActive {
                Log.info("「\(name)」不在设备列表里，不调整")
            }
        }
        apply(cfg)
    }

    private func applySwapped(_ cfg: DeviceConfig) -> DeviceConfig {
        guard swappedOrientation else { return cfg }
        var copy = cfg
        copy.width = cfg.height
        copy.height = cfg.width
        return copy
    }

    private func apply(_ cfg: DeviceConfig?) {
        defer { onChange?() }
        guard let cfg, cfg.kind != .computer, cfg.hasSize else {
            if display.isActive { display.remove() }
            return
        }
        let effective = applySwapped(cfg)
        if display.matches(effective) {
            if physicalDisableAllowed && !display.physicalOff {
                display.disablePhysicalIfNeeded()
            }
            return
        }
        display.create(effective)
    }

    private func keepWarmConfig() -> DeviceConfig? {
        guard let targetName = store.config.keepWarmDevice,
              let cfg = store.device(named: targetName),
              cfg.kind != .computer,
              cfg.hasSize else { return nil }
        return cfg
    }

    private func applyKeepWarmIfIdle() {
        guard !shuttingDown, !connected, !store.config.paused else { return }
        if let warm = keepWarmConfig() {
            if !display.matches(warm) {
                Log.info("待机预热虚拟屏：\(warm.name) (\(warm.sizeLabel))")
                display.create(warm)
            }
        } else if display.isActive {
            display.remove()
        }
        onChange?()
    }

    // MARK: - 菜单操作

    func setPaused(_ paused: Bool) {
        store.config.paused = paused
        if paused {
            display.remove()
        } else if connected {
            handleConnect()
        } else {
            applyKeepWarmIfIdle()
        }
        onChange?()
    }

    /// 配置变更后，若正在被控则按新配置重新应用；否则刷新待机保活
    func configChanged() {
        swappedOrientation = false
        if connected, !store.config.paused {
            if let name = simulatedName ?? controllerName ?? monitor.currentController {
                resolve(name)
            } else {
                handleConnect()
            }
        } else {
            applyKeepWarmIfIdle()
        }
        onChange?()
    }

    /// 一键切换当前虚拟屏横竖屏（当前会话有效，不改永久配置）
    func swapOrientation() {
        guard display.isActive, let current = display.current, current.width != current.height else { return }
        swappedOrientation.toggle()
        var flipped = current
        flipped.width = current.height
        flipped.height = current.width
        Log.info("横竖屏互换：\(current.sizeLabel) → \(flipped.sizeLabel)")
        display.create(flipped)
        onChange?()
    }

    /// 快捷键 ⌃⌥⌘9 / 菜单：立即恢复物理屏
    func restorePhysical() {
        Log.info("手动恢复物理屏")
        display.restorePhysicalNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func retryRecovery() {
        Log.info("手动触发恢复检查")
        display.retryRecovery()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func clearResidualRecovery() {
        display.clearResidualMarkers()
        onChange?()
    }

    func setDisablePhysical(_ on: Bool) {
        store.config.disablePhysical = on
        if on {
            if physicalDisableAllowed { display.disablePhysicalIfNeeded() }
        } else {
            display.restorePhysicalNow(override: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.onChange?() }
    }

    func shutdown(completion: @escaping () -> Void) {
        shuttingDown = true
        monitor.stop()
        display.remove(completion: completion)
    }
}
