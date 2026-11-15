// 远程期间禁用物理屏（CGSConfigureDisplayEnabled 私有 API）及其兜底恢复
// 实测（macOS 27）：
//   - 禁用不受 .forAppOnly 约束，进程退出后不会自动恢复，必须由别的进程重新启用
//   - 被禁用的屏会从 CGGetOnlineDisplayList 中消失，所以禁用前必须先把 ID 写盘
//   - 无头 Mac（无真实物理显示器）系统生成的 1920x1080 占位屏为 vendor='unkn' (0x756E6B6E) / model='virt' (0x76697274)，
//     决不能当成物理屏禁用（否则虚拟屏上线后占位屏会被销毁，恢复时持续报 CGError=1001 死锁）
import CoreGraphics
import Foundation

/// 同步执行一次显示器配置事务。GUI 进程中不可在主线程调用（会与自身重配置通知死锁）
@discardableResult
func applyDisplayConfig(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return .failure }
    body(cfg)
    let err = CGCompleteDisplayConfiguration(cfg, .forSession)
    if err != .success { CGCancelDisplayConfiguration(cfg) }
    return err
}

enum PhysicalDisplays {
    static let virtualVendorID: UInt32 = 0x5555
    static let headlessVendorID: UInt32 = 0x756E_6B6E  // 'unkn'
    static let headlessModelID: UInt32 = 0x7669_7274   // 'virt'

    private typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let setEnabled: EnableFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled")
        .map { unsafeBitCast($0, to: EnableFn.self) }

    static var available: Bool { setEnabled != nil }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == virtualVendorID
    }

    static func isHeadlessPlaceholder(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == headlessVendorID || CGDisplayModelNumber(id) == headlessModelID
    }

    static func realPhysicalDisplays(in online: [CGDirectDisplayID]) -> [CGDirectDisplayID] {
        online.filter { !isVirtual($0) && !isHeadlessPlaceholder($0) }
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// 已被禁用、待恢复的物理屏记录
    static let markerURL = ConfigStore.dir.appendingPathComponent("disabled-displays.json")

    static var pending: [CGDirectDisplayID]? { pending(from: markerURL) }

    static func pending(from url: URL) -> [CGDirectDisplayID]? {
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([CGDirectDisplayID].self, from: data), !ids.isEmpty else { return nil }
        return ids
    }

    static func clearMarker(at url: URL = markerURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 先记账再禁用。自动过滤虚拟屏和无头占位屏。须在后台队列调用
    static func disable(_ ids: [CGDirectDisplayID]) -> CGError {
        let targets = ids.filter { !isVirtual($0) && !isHeadlessPlaceholder($0) }
        guard !targets.isEmpty else { return .success }
        guard let setEnabled else { return .failure }
        let hadPrior = (pending?.isEmpty == false)
        let merged = Array(Set((pending ?? []) + targets)).sorted()
        guard (try? JSONEncoder().encode(merged).write(to: markerURL, options: .atomic)) != nil else {
            Log.info("❌ 无法写入物理屏记录，放弃禁用")
            return .failure
        }
        let err = applyDisplayConfig { cfg in targets.forEach { _ = setEnabled(cfg, $0, false) } }
        if err != .success && !hadPrior {
            try? FileManager.default.removeItem(at: markerURL)
        }
        return err
    }

    struct RestoreResult: Equatable {
        var remaining: [CGDirectDisplayID]
        var alreadyActive: [CGDirectDisplayID]
        var restored: [CGDirectDisplayID]
        var invalidated: [CGDirectDisplayID]
        var lastError: CGError
    }

    /// 可测试的纯恢复状态机：
    /// 1. 跳过已处于 active 的 ID；
    /// 2. 剩余 ID 先尝试批量启用；
    /// 3. 批量失败则逐个启用，`.illegalArgument` (1001) 视作已失效残留 ID 自动剔除，其它错误保留重试。
    static func restoreIds(
        _ ids: [CGDirectDisplayID],
        activeIds: Set<CGDirectDisplayID>,
        enableBatch: ([CGDirectDisplayID]) -> CGError,
        enableSingle: (CGDirectDisplayID) -> CGError
    ) -> RestoreResult {
        var alreadyActive: [CGDirectDisplayID] = []
        var needEnable: [CGDirectDisplayID] = []
        for id in ids {
            if activeIds.contains(id) {
                alreadyActive.append(id)
            } else {
                needEnable.append(id)
            }
        }
        if needEnable.isEmpty {
            return RestoreResult(remaining: [], alreadyActive: alreadyActive, restored: [], invalidated: [], lastError: .success)
        }

        let batchErr = enableBatch(needEnable)
        if batchErr == .success {
            return RestoreResult(remaining: [], alreadyActive: alreadyActive, restored: needEnable, invalidated: [], lastError: .success)
        }

        var restored: [CGDirectDisplayID] = []
        var invalidated: [CGDirectDisplayID] = []
        var remaining: [CGDirectDisplayID] = []
        var lastErr = batchErr
        for id in needEnable {
            let err = enableSingle(id)
            if err == .success {
                restored.append(id)
            } else if err == .illegalArgument {
                invalidated.append(id)
            } else {
                remaining.append(id)
                lastErr = err
            }
        }
        return RestoreResult(remaining: remaining, alreadyActive: alreadyActive, restored: restored, invalidated: invalidated, lastError: lastErr)
    }

    /// 按记录重新启用物理屏；全部解决（恢复/已在线/失效清理）后删除记录。可在任意进程调用，重复调用无害
    @discardableResult
    static func restore(reason: String, markerURL: URL = PhysicalDisplays.markerURL) -> Bool {
        guard let ids = pending(from: markerURL) else { return true }
        guard let setEnabled else { return false }

        let result = restoreIds(
            ids,
            activeIds: Set(activeDisplays()),
            enableBatch: { batch in
                applyDisplayConfig { cfg in batch.forEach { _ = setEnabled(cfg, $0, true) } }
            },
            enableSingle: { id in
                applyDisplayConfig { cfg in _ = setEnabled(cfg, id, true) }
            }
        )

        if result.remaining.isEmpty {
            try? FileManager.default.removeItem(at: markerURL)
            var parts: [String] = []
            if !result.restored.isEmpty { parts.append("已恢复 \(result.restored)") }
            if !result.alreadyActive.isEmpty { parts.append("已在线 \(result.alreadyActive)") }
            if !result.invalidated.isEmpty { parts.append("已清理失效 ID \(result.invalidated)") }
            let summary = parts.isEmpty ? "已清理记录" : parts.joined(separator: "，")
            Log.info("✅ 物理屏处理完成（\(reason)）：\(summary)")
            return true
        }

        if result.remaining != ids {
            try? JSONEncoder().encode(result.remaining).write(to: markerURL, options: .atomic)
        }
        Log.info("⚠️ 恢复物理屏失败 CGError=\(result.lastError.rawValue)（\(reason)），待重试 \(result.remaining)（已清理失效 \(result.invalidated)）")
        return false
    }
}
