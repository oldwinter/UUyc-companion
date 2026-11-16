import ApplicationServices
import Foundation

private func textNode(_ value: String) -> UUAXTreeNode {
    UUAXTreeNode(role: kAXStaticTextRole, value: value)
}

private func groupNode(_ children: [UUAXTreeNode], role: String = kAXGroupRole) -> UUAXTreeNode {
    UUAXTreeNode(role: role, children: children)
}

private func controllerRow(_ name: String, duration: String = "连接时长 00:12") -> UUAXTreeNode {
    UUAXTreeNode(role: kAXRowRole, children: [
        textNode(name),
        textNode("远程控制"),
        textNode(duration),
    ])
}

@main struct ReaderTests {
    static func main() {
        // 1. 正常「本机被控中」树（扁平窗口同级标题 + 表格，清理 (selected) 前缀与重复行）
        let flatControlledTree = UUAXTreeNode(role: kAXWindowRole, children: [
            groupNode([
                textNode("全部设备"),
                textNode("本机被控中"),
            ]),
            textNode("本机被控中"),
            groupNode([
                controllerRow("(selected) iPhone 17"),
                controllerRow("iPhone 17"),
                UUAXTreeNode(role: kAXRowRole, children: [textNode("无关表格行")]),
            ], role: kAXTableRole),
        ])
        let r1 = UUReader.parseControllers(in: [flatControlledTree], truncated: false)
        precondition(r1 == ["iPhone 17"], "正常扁平本机被控页应解析出 iPhone 17，实际 \(String(describing: r1))")

        // 1b. 独立页面容器下的「控制此电脑」树（带轻量标题包装与 ScrollArea）
        let nestedControlledTree = UUAXTreeNode(role: kAXWindowRole, children: [
            groupNode([textNode("全部设备")]),
            groupNode([
                groupNode([textNode("控制此电脑")]),
                groupNode([
                    textNode("当前连接列表"),
                    groupNode([
                        controllerRow("company M4"),
                    ], role: kAXTableRole),
                ]),
            ]),
        ])
        let r1b = UUReader.parseControllers(in: [nestedControlledTree], truncated: false)
        precondition(r1b == ["company M4"], "独立页面容器应解析出 company M4，实际 \(String(describing: r1b))")

        // 2. 空闲本机停留在同账号另一台 Mac 的详情页（含「远程控制」行但无本机被控标题）：绝不能误触发
        let detailPageWhileIdle = UUAXTreeNode(role: kAXWindowRole, children: [
            groupNode([textNode("全部设备"), textNode("我的设备")]),
            groupNode([
                textNode("company mac studio"),
                textNode("设备详情"),
                groupNode([
                    controllerRow("iPhone Air"),
                ], role: kAXTableRole),
            ]),
        ])
        let r2 = UUReader.parseControllers(in: [detailPageWhileIdle], truncated: false)
        precondition(r2 == [], "停在同账号另一台 Mac 详情页时应返回空数组，实际 \(String(describing: r2))")

        // 3a. 侧边栏有「本机被控中」小卡片且和「全部设备」同组，主区域停在另一台 Mac 详情页：不得混入详情页控制端
        let sidebarCardPlusDetail = UUAXTreeNode(role: kAXWindowRole, children: [
            groupNode([
                groupNode([textNode("本机被控中"), textNode("点击查看")]),
                textNode("全部设备"),
            ]),
            groupNode([
                textNode("company mac studio"),
                groupNode([
                    controllerRow("iPhone Air"),
                ], role: kAXTableRole),
            ]),
        ])
        let r3a = UUReader.parseControllers(in: [sidebarCardPlusDetail], truncated: false)
        precondition(r3a == [], "侧边栏卡片 + 另一台 Mac 详情页不得误认 iPhone Air，实际 \(String(describing: r3a))")

        // 3b. 侧边栏卡片独立分组（不含全部设备）+ 同级导航分组 + 主区域另一台 Mac 详情页：同样不得混入
        let splitSidebarCardPlusDetail = UUAXTreeNode(role: kAXWindowRole, children: [
            groupNode([textNode("本机被控中")]),
            groupNode([textNode("全部设备")]),
            groupNode([
                textNode("company mac studio"),
                groupNode([
                    controllerRow("iPhone Air"),
                ], role: kAXTableRole),
            ]),
        ])
        let r3b = UUReader.parseControllers(in: [splitSidebarCardPlusDetail], truncated: false)
        precondition(r3b == [], "分栏卡片 + 详情页不得误认 iPhone Air，实际 \(String(describing: r3b))")

        // 4. 遍历截断 / 无可读文字兜底：truncated=true 且无匹配行返回 nil；truncated=false 且有静态文本无匹配返回 []；无静态文本返回 nil
        let truncatedEmpty = UUReader.parseControllers(in: [groupNode([textNode("加载中")])], truncated: true)
        precondition(truncatedEmpty == nil, "遍历截断且无权威控制行时应返回 nil 保留缓存")

        let cleanIdle = UUReader.parseControllers(in: [groupNode([textNode("全部设备")])], truncated: false)
        precondition(cleanIdle == [], "未截断且有文本但无控制行时应返回 []")

        let unreadable = UUReader.parseControllers(in: [groupNode([])], truncated: false)
        precondition(unreadable == nil, "没有任何可读静态文本时应返回 nil")

        print("PASS: UUReader parseControllers authoritative controlled table, detail-page anti-spoof, and truncation handling")
    }
}
