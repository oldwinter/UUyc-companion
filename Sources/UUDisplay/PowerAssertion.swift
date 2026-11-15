// IOKit 电源断言工具：
// 1. 检测 UURemoteServer 是否持有 PreventUserIdleDisplaySleep（零权限、跨全屏、不抖动的原生远控在线信号）
// 2. 在远控建屏与断开收尾窗口持有伴侣自己的防屏幕休眠断言，避免断开瞬间空闲休眠导致 CGError=1014
import Foundation
import IOKit.pwr_mgt

enum UUPowerAssertion {
    /// UURemoteServer 正在推流/被控时系统会持有 PreventUserIdleDisplaySleep 断言
    static func uuServerHasDisplayAssertion() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [AnyHashable: Any] else {
            return false
        }
        for value in dict.values {
            guard let list = value as? [[String: Any]] else { continue }
            for item in list {
                let proc = (item["Process Name"] as? String) ?? ""
                let type = (item[kIOPMAssertionTypeKey as String] as? String)
                    ?? (item["AssertType"] as? String) ?? ""
                if proc == "UURemoteServer",
                   type == kIOPMAssertionTypePreventUserIdleDisplaySleep || type == "PreventUserIdleDisplaySleep" {
                    return true
                }
            }
        }
        return false
    }
}

/// 远控会话期间的防屏幕休眠守护（限时断言 + 平滑续期，先建新再释旧）
final class DisplaySleepGuard {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var renewTimer: Timer?
    private let lock = NSLock()

    deinit {
        end()
    }

    func beginSession() {
        lock.lock()
        let alreadyActive = assertionID != IOPMAssertionID(0) && renewTimer != nil
        lock.unlock()
        if alreadyActive { return }

        acquire(timeout: 45, reason: "UUyc companion active remote display session")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renewTimer?.invalidate()
            self.renewTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.acquire(timeout: 45, reason: "UUyc companion active remote display session")
            }
        }
    }

    /// 断开阶段：停止续期，换为 30 秒不续期的收尾保护断言
    func beginClosing() {
        DispatchQueue.main.async { [weak self] in
            self?.renewTimer?.invalidate()
            self?.renewTimer = nil
        }
        acquire(timeout: 30, reason: "UUyc companion display teardown handoff")
    }

    func end() {
        if Thread.isMainThread {
            renewTimer?.invalidate()
            renewTimer = nil
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.renewTimer?.invalidate()
                self?.renewTimer = nil
            }
        }
        lock.lock()
        let old = assertionID
        assertionID = IOPMAssertionID(0)
        lock.unlock()
        if old != IOPMAssertionID(0) {
            IOPMAssertionRelease(old)
        }
    }

    private func acquire(timeout: CFTimeInterval, reason: String) {
        var nextID: IOPMAssertionID = IOPMAssertionID(0)
        let rc = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            reason as CFString,
            nil, nil, nil,
            timeout,
            kIOPMAssertionTimeoutActionRelease as CFString,
            &nextID
        )
        guard rc == kIOReturnSuccess else { return }
        lock.lock()
        let old = assertionID
        assertionID = nextID
        lock.unlock()
        if old != IOPMAssertionID(0) {
            IOPMAssertionRelease(old)
        }
    }
}
