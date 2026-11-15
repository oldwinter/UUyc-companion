import CoreGraphics
import Foundation

@main struct PhysicalDisplayTests {
    static func main() {
        // 1. 全部已在活跃列表中：跳过批处理与单屏启用
        let r1 = PhysicalDisplays.restoreIds(
            [7, 13],
            activeIds: [7, 13],
            enableBatch: { _ in preconditionFailure("已在线不应调用 enableBatch") },
            enableSingle: { _ in preconditionFailure("已在线不应调用 enableSingle") }
        )
        precondition(r1.remaining.isEmpty)
        precondition(r1.alreadyActive == [7, 13])

        // 2. 只有 macOS 无头占位屏 #7，返回 1001 (.illegalArgument) 时视作已失效清理出 remaining
        let r2 = PhysicalDisplays.restoreIds(
            [7],
            activeIds: [],
            enableBatch: { _ in .illegalArgument },
            enableSingle: { id in id == 7 ? .illegalArgument : .failure }
        )
        precondition(r2.remaining.isEmpty, "1001 占位屏应从待恢复队列清理，防止无限死循环")
        precondition(r2.invalidated == [7])

        // 3. 混合：真物理屏 #1 恢复成功，失效占位屏 #7 返回 1001
        let r3 = PhysicalDisplays.restoreIds(
            [1, 7],
            activeIds: [],
            enableBatch: { _ in .illegalArgument },
            enableSingle: { id in id == 1 ? .success : .illegalArgument }
        )
        precondition(r3.remaining.isEmpty)
        precondition(r3.restored == [1])
        precondition(r3.invalidated == [7])

        // 4. 混合短暂失败：#1 恢复成功，#2 返回暂态错误 (.failure) 应缩窄 remaining 并保留重试
        let r4 = PhysicalDisplays.restoreIds(
            [1, 2],
            activeIds: [],
            enableBatch: { _ in .failure },
            enableSingle: { id in id == 1 ? .success : .failure }
        )
        precondition(r4.remaining == [2])
        precondition(r4.restored == [1])
        precondition(r4.invalidated.isEmpty)
        precondition(r4.lastError == .failure)

        // 5. Marker 文件写入与清除测试
        let tempMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("uu-physical-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempMarker) }
        try! JSONEncoder().encode([UInt32(7)]).write(to: tempMarker)
        precondition(PhysicalDisplays.pending(from: tempMarker) == [7])
        PhysicalDisplays.clearMarker(at: tempMarker)
        precondition(PhysicalDisplays.pending(from: tempMarker) == nil)

        print("PASS: PhysicalDisplays.restoreIds active/headless-1001/mixed/transient-shrink & marker cleanup")
    }
}
