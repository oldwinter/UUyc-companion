// 合并覆盖窗口、UURemoteServer 防息屏断言与 UU 被控设备表格，兼容无覆盖窗口/跨平台远控会话。
// 采用三档自适应轮询：空闲待机 & 稳定远控降频读取 AX，状态切换瞬间零等待唤醒。
import CoreGraphics
import Foundation

final class UUMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onControllersUpdate: (([String]?) -> Void)?
    var onTrustChange: ((Bool) -> Void)?
    private(set) var connected = false
    private(set) var lastTrusted: Bool?
    var currentController: String? { session.controller }

    private var timer: Timer?
    private var session = UUConnectionState()
    private let readerQueue = DispatchQueue(label: "uudisplay.controller-reader", qos: .utility)
    private var readInFlight = false
    private var controllers: [String]?
    private var controllersReadAt = Date.distantPast
    private var lastOverlay = false

    private let trusted: () -> Bool
    private let readControllers: () -> [String]?
    private let hasOverlay: () -> Bool
    private let isUURunning: () -> Bool
    private let tickInterval: TimeInterval
    private let cacheTTL: TimeInterval
    private let staleReadLimit: TimeInterval
    private let idleAXInterval: TimeInterval
    private let stableAXInterval: TimeInterval

    init(trusted: @escaping () -> Bool = { UUReader.isTrusted },
         readControllers: @escaping () -> [String]? = { UUReader.readControllers() },
         hasOverlay: @escaping () -> Bool = { UUPowerAssertion.uuServerHasDisplayAssertion() || UUMonitor.overlayPresent() },
         isUURunning: @escaping () -> Bool = { true },
         tickInterval: TimeInterval = 1.0,
         cacheTTL: TimeInterval = 3.5,
         staleReadLimit: TimeInterval = 2.5,
         idleAXInterval: TimeInterval = 5.0,
         stableAXInterval: TimeInterval = 5.0) {
        self.trusted = trusted
        self.readControllers = readControllers
        self.hasOverlay = hasOverlay
        self.isUURunning = isUURunning
        self.tickInterval = tickInterval
        self.cacheTTL = cacheTTL
        self.staleReadLimit = staleReadLimit
        self.idleAXInterval = idleAXInterval
        self.stableAXInterval = stableAXInterval
    }

    static func overlayPresent() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "UURemoteServer" }
    }

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = min(0.15, tickInterval * 0.15)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        controllers = nil
        controllersReadAt = .distantPast
        lastOverlay = false
        readInFlight = false
    }

    /// 唤醒后立即刷新一次，跳过空闲节流周期
    func poke() {
        controllersReadAt = .distantPast
        if timer != nil {
            tick()
        }
    }

    private func tick() {
        let isTrusted = trusted()
        if lastTrusted != isTrusted {
            lastTrusted = isTrusted
            onTrustChange?(isTrusted)
        }

        let overlayNow = hasOverlay()
        let overlayJustAppeared = overlayNow && !lastOverlay
        let overlayJustDropped = !overlayNow && lastOverlay
        lastOverlay = overlayNow

        guard isTrusted else {
            controllers = nil
            controllersReadAt = .distantPast
            apply(overlay: overlayNow, controllers: nil)
            return
        }

        if overlayJustDropped {
            controllers = nil
            controllersReadAt = .distantPast
        }

        let stableOverlaySession = connected && overlayNow && session.controller != nil
        let effectiveCacheTTL = stableOverlaySession
            ? max(cacheTTL, stableAXInterval + staleReadLimit)
            : cacheTTL
        let now = Date()
        // 每次 tick 仍检测覆盖窗口/断言；在有效期内保留最近一次有效 AX 快照，避免慢读取或降频期间闪烁。
        let fresh = now.timeIntervalSince(controllersReadAt) <= effectiveCacheTTL
        apply(overlay: overlayNow, controllers: fresh ? controllers : nil)

        guard isUURunning() else {
            controllers = nil
            controllersReadAt = .distantPast
            return
        }

        // AX 调用可能阻塞；后台串行读取且不堆积任务。
        guard !readInFlight else { return }

        let sinceLastRead = now.timeIntervalSince(controllersReadAt)
        let shouldReadAX: Bool
        if overlayJustAppeared || overlayJustDropped {
            shouldReadAX = true
        } else if !connected && !overlayNow {
            // 档位 1：空闲待机，降低后台 AX 轮询频率
            shouldReadAX = sinceLastRead >= idleAXInterval
        } else if stableOverlaySession {
            // 档位 3：有底层在线断言/覆盖窗口兜底的稳定会话，低频检查是否换设备
            shouldReadAX = sinceLastRead >= stableAXInterval
        } else {
            // 档位 2：刚连入待识别控制端，或纯 AX 无覆盖窗口会话
            shouldReadAX = true
        }
        guard shouldReadAX else { return }

        readInFlight = true
        let started = Date()
        let read = readControllers
        readerQueue.async { [weak self] in
            let result = read()
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readInFlight = false
                // 丢弃延迟过久的界面快照，避免断线后旧快照误触发重连。
                guard elapsed <= self.staleReadLimit else { return }
                let currentOverlay = self.hasOverlay()
                self.controllers = result
                self.controllersReadAt = Date()
                self.onControllersUpdate?(result)
                self.apply(overlay: currentOverlay, controllers: result)
            }
        }
    }

    private func apply(overlay: Bool, controllers: [String]?) {
        switch session.update(overlay: overlay, controllers: controllers, now: Date()) {
        case .connected:
            connected = true
            Log.info("检测到 UU 连入（覆盖窗口、防息屏断言或被控设备表格）")
            onConnect?()
        case .controllerChanged:
            Log.info("检测到 UU 控制端变化")
            onConnect?()
        case .disconnected:
            connected = false
            Log.info("检测到 UU 断开")
            onDisconnect?()
        case nil:
            break
        }
    }
}
