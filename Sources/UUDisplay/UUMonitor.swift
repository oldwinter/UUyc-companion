// 合并覆盖窗口、UURemoteServer 防息屏断言与 UU 被控设备表格，兼容无覆盖窗口/跨平台远控会话。
import CoreGraphics
import Foundation

final class UUMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onControllersUpdate: (([String]?) -> Void)?
    private(set) var connected = false
    var currentController: String? { session.controller }

    private var timer: Timer?
    private var session = UUConnectionState()
    private let readerQueue = DispatchQueue(label: "uudisplay.controller-reader", qos: .utility)
    private var readInFlight = false
    private var controllers: [String]?
    private var controllersReadAt = Date.distantPast

    private let trusted: () -> Bool
    private let readControllers: () -> [String]?
    private let hasOverlay: () -> Bool
    private let tickInterval: TimeInterval
    private let cacheTTL: TimeInterval
    private let staleReadLimit: TimeInterval

    init(trusted: @escaping () -> Bool = { UUReader.isTrusted },
         readControllers: @escaping () -> [String]? = { UUReader.readControllers() },
         hasOverlay: @escaping () -> Bool = { UUMonitor.overlayPresent() || UUPowerAssertion.uuServerHasDisplayAssertion() },
         tickInterval: TimeInterval = 1.0,
         cacheTTL: TimeInterval = 3.5,
         staleReadLimit: TimeInterval = 2.5) {
        self.trusted = trusted
        self.readControllers = readControllers
        self.hasOverlay = hasOverlay
        self.tickInterval = tickInterval
        self.cacheTTL = cacheTTL
        self.staleReadLimit = staleReadLimit
    }

    static func overlayPresent() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "UURemoteServer" }
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        controllers = nil
        controllersReadAt = .distantPast
    }

    private func tick() {
        guard trusted() else {
            controllers = nil
            controllersReadAt = .distantPast
            apply(controllers: nil)
            return
        }
        // 每次 tick 仍检测覆盖窗口；在 cacheTTL 内保留最近一次有效 AX 快照，避免慢读取期间频繁闪烁。
        let fresh = Date().timeIntervalSince(controllersReadAt) <= cacheTTL
        apply(controllers: fresh ? controllers : nil)
        // AX 调用可能阻塞；后台串行读取且不堆积任务。
        guard !readInFlight else { return }
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
                self.controllers = result
                self.controllersReadAt = Date()
                self.onControllersUpdate?(result)
                self.apply(controllers: result)
            }
        }
    }

    private func apply(controllers: [String]?) {
        switch session.update(overlay: hasOverlay(), controllers: controllers, now: Date()) {
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
