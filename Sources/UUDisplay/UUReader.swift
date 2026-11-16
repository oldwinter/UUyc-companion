// 通过辅助功能 API 读取 UU远程 主界面：设备列表、当前控制端设备名
import AppKit
import ApplicationServices

struct UUDevice: Hashable {
    let name: String
    let isComputerGroup: Bool
    let isSelf: Bool
    /// UU 图标里的系统类型：macos / ios / android / windows…
    var platform: String = ""
}

/// 剥离出来的可测 AX 树节点，用于纯逻辑测试（无需真实 UU 进程）
struct UUAXTreeNode {
    let role: String
    let value: String?
    let description: String?
    let identifier: String?
    let positionY: CGFloat
    let children: [UUAXTreeNode]

    init(
        role: String,
        value: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        positionY: CGFloat = 0,
        children: [UUAXTreeNode] = []
    ) {
        self.role = role
        self.value = value
        self.description = description
        self.identifier = identifier
        self.positionY = positionY
        self.children = children
    }
}

enum UUReader {
    static let bundleID = "com.netease.uuremote"

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func appElement() -> AXUIElement? {
        guard let app, !app.isTerminated else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1.0)  // UU 卡顿时不阻塞主线程太久
        return ax
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func role(_ el: AXUIElement) -> String? { attr(el, kAXRoleAttribute) as? String }
    private static func value(_ el: AXUIElement) -> String? { attr(el, kAXValueAttribute) as? String }

    private static let maxFlattenNodes = 2048

    /// 纯叶子角色：跳过 kAXChildrenAttribute IPC，显著降低跨进程 AX 开销
    private static let leafRoles: Set<String> = [
        kAXStaticTextRole,
        kAXImageRole,
        kAXScrollBarRole,
        kAXSliderRole,
        kAXProgressIndicatorRole,
        kAXBusyIndicatorRole,
        "AXSplitter",
    ]

    private struct AXElementKey: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// 先序遍历；UU 的 AX 树存在环，必须去重并限制深度与总节点数，防止内存膨胀或卡死。
    private static func flatten(
        _ el: AXUIElement,
        depth: Int = 0,
        visited: inout Set<AXElementKey>,
        into out: inout [(element: AXUIElement, role: String)]
    ) {
        guard depth < 25, out.count < maxFlattenNodes else { return }
        let key = AXElementKey(element: el)
        guard visited.insert(key).inserted else { return }
        let r = role(el) ?? ""
        out.append((el, r))
        guard !leafRoles.contains(r), out.count < maxFlattenNodes else { return }
        let children: [AXUIElement] = autoreleasepool {
            (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        for k in children {
            guard out.count < maxFlattenNodes else { break }
            flatten(k, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    private static func flattenTree(_ roots: [AXUIElement]) -> [(element: AXUIElement, role: String)] {
        var visited = Set<AXElementKey>()
        var out: [(element: AXUIElement, role: String)] = []
        for root in roots {
            flatten(root, visited: &visited, into: &out)
        }
        return out
    }

    /// 合并 windows / mainWindow / focusedWindow 并去重，覆盖全屏 Space 场景。
    private static func windows() -> [AXUIElement] {
        guard let ax = appElement() else { return [] }
        var result: [AXUIElement] = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for singleAttr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let w = attr(ax, singleAttr), CFGetTypeID(w) == AXUIElementGetTypeID() {
                let win = w as! AXUIElement
                if !result.contains(where: { CFEqual($0, win) }) {
                    result.append(win)
                }
            }
        }
        return result
    }

    static var hasMainWindow: Bool { !windows().isEmpty }

    /// 点 UU 菜单栏图标里的「显示主界面」
    @discardableResult
    static func showMainWindow() -> Bool {
        guard let ax = appElement(), let bar = attr(ax, kAXExtrasMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        let all = flattenTree([bar as! AXUIElement])
        guard let item = all.first(where: { (attr($0.element, kAXIdentifierAttribute) as? String) == "showWindow" }) else { return false }
        return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    /// 读取「全部设备」列表。主窗口不存在返回 nil。
    /// 结构：分组标题（电脑 / 手机/平板）→ 32 号设备图标 + 设备名 [+ 「本机」]
    static func readDevices() -> [UUDevice]? {
        let wins = windows()
        guard !wins.isEmpty else { return nil }
        let all = flattenTree(wins)

        var group: Bool?  // true = 电脑组
        var pendingIcon = false
        var pendingPlatform = ""
        var pendingY: CGFloat = 0
        var ys: [String: CGFloat] = [:]  // AX 顺序与界面相反，按图标的纵坐标排回 UU 的显示顺序
        var result: [UUDevice] = []
        for (el, elRole) in all {
            switch elRole {
            case kAXImageRole:
                let d = attr(el, kAXDescriptionAttribute) as? String ?? ""
                pendingIcon = d.hasPrefix("icon device") && d.contains(" 32")
                if pendingIcon {
                    pendingPlatform = d.split(separator: " ").dropFirst(2).first.map(String.init) ?? ""
                    var pt = CGPoint.zero
                    if let v = attr(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
                        AXValueGetValue(v as! AXValue, .cgPoint, &pt)
                    }
                    pendingY = pt.y
                }
            case kAXStaticTextRole:
                guard let v = value(el)?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { continue }
                if v == "电脑" { group = true; pendingIcon = false }
                else if v == "手机/平板" { group = false; pendingIcon = false }
                else if v == "本机", let last = result.popLast() {
                    result.append(UUDevice(name: last.name, isComputerGroup: last.isComputerGroup, isSelf: true, platform: last.platform))
                } else if pendingIcon, let g = group {
                    if !result.contains(where: { $0.name == v }) {
                        result.append(UUDevice(name: v, isComputerGroup: g, isSelf: false, platform: pendingPlatform))
                        ys[v] = pendingY
                    }
                    pendingIcon = false
                }
            default:
                break
            }
        }
        return result.enumerated().sorted { (ys[$0.element.name] ?? 0, $0.offset) < (ys[$1.element.name] ?? 0, $1.offset) }.map(\.element)
    }

    static func cleanControllerName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("(selected)") {
            s = String(s.dropFirst("(selected)".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    // MARK: - 控制端表格解析与同账号多机防误触

    private struct RawAXNode {
        let element: AXUIElement
        let role: String
        var childIndices: [Int]
    }

    private static func isControlledHeading(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("本机被控") || trimmed.contains("控制此电脑")
    }

    private static func containsAllDevicesLabel(_ node: UUAXTreeNode) -> Bool {
        if node.role == kAXStaticTextRole,
           let val = node.value?.trimmingCharacters(in: .whitespacesAndNewlines),
           val.contains("全部设备") {
            return true
        }
        return node.children.contains(where: containsAllDevicesLabel)
    }

    private static func containsRow(_ node: UUAXTreeNode) -> Bool {
        if node.role == kAXRowRole { return true }
        return node.children.contains(where: containsRow)
    }

    private static func subtreeNodeCount(_ node: UUAXTreeNode, limit: Int = 16) -> Int {
        var total = 1
        for child in node.children {
            total += subtreeNodeCount(child, limit: limit - total)
            if total > limit { return total }
        }
        return total
    }

    private static func collectStaticTexts(in node: UUAXTreeNode, includeRows: Bool, excludeAllDevicesSubtree: Bool) -> [String] {
        if !includeRows && node.role == kAXRowRole { return [] }
        if excludeAllDevicesSubtree && containsAllDevicesLabel(node) { return [] }
        var out: [String] = []
        if node.role == kAXStaticTextRole, let raw = node.value {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        for child in node.children {
            out.append(contentsOf: collectStaticTexts(in: child, includeRows: includeRows, excludeAllDevicesSubtree: excludeAllDevicesSubtree))
        }
        return out
    }

    private static func hasReadableText(in node: UUAXTreeNode) -> Bool {
        if node.role == kAXStaticTextRole { return true }
        return node.children.contains(where: hasReadableText)
    }

    private static func extractRowController(from row: UUAXTreeNode) -> String? {
        let texts = collectStaticTexts(in: row, includeRows: true, excludeAllDevicesSubtree: false)
        guard texts.contains("远程控制") else { return nil }
        guard let rawName = texts.first(where: { $0 != "远程控制" && !$0.hasPrefix("连接时长") && !$0.isEmpty }) else {
            return nil
        }
        let name = cleanControllerName(rawName)
        return name.isEmpty ? nil : name
    }

    /// 检查容器是否带有「本机被控中 / 控制此电脑」标题（排除左侧导航栏「全部设备」及其所在子树）
    private static func hasAuthoritativeControlledMarker(in container: UUAXTreeNode, strictDirectHeaderOnly: Bool) -> Bool {
        for child in container.children {
            if child.role == kAXStaticTextRole, let v = child.value, isControlledHeading(v) {
                return true
            }
            if containsAllDevicesLabel(child) || containsRow(child) { continue }
            let isHeaderLike = child.role != kAXTableRole
                && child.role != kAXOutlineRole
                && child.role != kAXListRole
                && child.role != kAXScrollAreaRole
                && (!strictDirectHeaderOnly || subtreeNodeCount(child) <= 12)
            if isHeaderLike {
                let texts = collectStaticTexts(in: child, includeRows: false, excludeAllDevicesSubtree: true)
                if texts.contains(where: isControlledHeading) {
                    return true
                }
            }
        }
        return false
    }

    private static let containerWrapperRoles: Set<String> = [
        kAXTableRole, kAXOutlineRole, kAXListRole, kAXScrollAreaRole
    ]

    /// 沿祖先链判断该行是否隶属于「本机被控页」表格（防止停在同账号另一台 Mac 的详情页时误触发）
    private static func isRowAuthoritative(ancestors: [UUAXTreeNode]) -> Bool {
        var passedNonWrapperTitledGroup = false
        for (offset, ancestor) in ancestors.reversed().enumerated() {
            let isRootWindow = (offset == ancestors.count - 1) || ancestor.role == kAXWindowRole
            let hasSidebarNav = containsAllDevicesLabel(ancestor)
            if hasSidebarNav {
                // 若子级页面已有独立标题（如某台 Mac 的设备详情页）且不含本机被控标题，不能再被外层窗口/分栏的侧边栏卡片误授权
                if passedNonWrapperTitledGroup { return false }
                if !isRootWindow {
                    if hasAuthoritativeControlledMarker(in: ancestor, strictDirectHeaderOnly: true) {
                        return true
                    }
                    continue
                }
            }

            if hasAuthoritativeControlledMarker(in: ancestor, strictDirectHeaderOnly: isRootWindow && hasSidebarNav) {
                return true
            }

            if !isRootWindow && !containerWrapperRoles.contains(ancestor.role) {
                let ownTexts = collectStaticTexts(in: ancestor, includeRows: false, excludeAllDevicesSubtree: true)
                if !ownTexts.isEmpty {
                    passedNonWrapperTitledGroup = true
                }
            }
        }
        return false
    }

    /// 纯函数解析控制端名称：主窗口缺少可读文字或遍历被截断时返回 nil，确定无人控制本机返回 []
    static func parseControllers(in roots: [UUAXTreeNode], truncated: Bool) -> [String]? {
        var authoritativeNames: [String] = []
        var unanchoredNames: [String] = []
        var anyReadableText = false

        func walk(_ node: UUAXTreeNode, ancestors: [UUAXTreeNode]) {
            if node.role == kAXStaticTextRole { anyReadableText = true }
            if node.role == kAXRowRole {
                if !anyReadableText && hasReadableText(in: node) { anyReadableText = true }
                if let name = extractRowController(from: node) {
                    if isRowAuthoritative(ancestors: ancestors) {
                        if !authoritativeNames.contains(name) { authoritativeNames.append(name) }
                    } else {
                        if !unanchoredNames.contains(name) { unanchoredNames.append(name) }
                    }
                }
                return
            }
            var nextAncestors = ancestors
            nextAncestors.append(node)
            for child in node.children {
                walk(child, ancestors: nextAncestors)
            }
        }

        for root in roots {
            walk(root, ancestors: [])
        }

        if !authoritativeNames.isEmpty {
            return authoritativeNames
        }

        if !unanchoredNames.isEmpty {
            // 若窗口中存在「全部设备」主导航栏而没有任何行隶属「本机被控」区块，说明行来自另一台设备的详情页，绝不误认
            let hasAllDevicesNav = roots.contains(where: containsAllDevicesLabel)
            if !hasAllDevicesNav {
                let nonRowTexts = roots.flatMap { collectStaticTexts(in: $0, includeRows: false, excludeAllDevicesSubtree: true) }
                if nonRowTexts.contains(where: isControlledHeading) {
                    return unanchoredNames
                }
            }
        }

        if !anyReadableText || truncated {
            return nil
        }
        return []
    }

    /// 读取「本机被控中」表格里的控制端设备名。主窗口不存在或遍历不完整返回 nil，无人控制返回 []
    /// 采用单遍低 IPC 遍历：先仅查 kAXRoleAttribute 并跳过叶子节点的 kAXChildrenAttribute；
    /// 绝大多数空闲帧没有 AXRow 或没有「远程控制」行，可零 kAXValueAttribute IPC 直接返回。
    static func readControllers() -> [String]? {
        let wins = windows()
        guard !wins.isEmpty else { return nil }

        var rawNodes: [RawAXNode] = []
        var visited = Set<AXElementKey>()
        var rootIndices: [Int] = []
        var rowIndices: [Int] = []
        var hasStaticText = false

        func scan(_ el: AXUIElement, depth: Int) -> Int? {
            guard depth < 25, rawNodes.count < maxFlattenNodes else { return nil }
            let key = AXElementKey(element: el)
            guard visited.insert(key).inserted else { return nil }

            let r = role(el) ?? ""
            let idx = rawNodes.count
            rawNodes.append(RawAXNode(element: el, role: r, childIndices: []))
            if r == kAXRowRole { rowIndices.append(idx) }
            if r == kAXStaticTextRole { hasStaticText = true }

            guard !leafRoles.contains(r), rawNodes.count < maxFlattenNodes else { return idx }
            let children: [AXUIElement] = autoreleasepool {
                (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            var childIDs: [Int] = []
            for k in children {
                guard rawNodes.count < maxFlattenNodes else { break }
                if let cIdx = scan(k, depth: depth + 1) {
                    childIDs.append(cIdx)
                }
            }
            rawNodes[idx].childIndices = childIDs
            return idx
        }

        for w in wins {
            guard rawNodes.count < maxFlattenNodes else { break }
            if let rIdx = scan(w, depth: 0) {
                rootIndices.append(rIdx)
            }
        }

        let truncated = rawNodes.count >= maxFlattenNodes
        if rowIndices.isEmpty {
            return (!hasStaticText || truncated) ? nil : []
        }

        var valueCache: [Int: String] = [:]
        func cachedValue(at index: Int) -> String? {
            if let cached = valueCache[index] { return cached.isEmpty ? nil : cached }
            let val = value(rawNodes[index].element) ?? ""
            valueCache[index] = val
            return val.isEmpty ? nil : val
        }

        func subtreeHasRemoteControl(_ index: Int) -> Bool {
            let node = rawNodes[index]
            if node.role == kAXStaticTextRole,
               let v = cachedValue(at: index)?.trimmingCharacters(in: .whitespacesAndNewlines),
               v == "远程控制" {
                return true
            }
            return node.childIndices.contains(where: subtreeHasRemoteControl)
        }

        // 快速短路 #2：存在表格行（例如设备列表表格），但没有任何行包含「远程控制」
        guard rowIndices.contains(where: subtreeHasRemoteControl) else {
            return (!hasStaticText || truncated) ? nil : []
        }

        // 仅在存在真实控制行时，才补读非行节点的文本构造结构树并判定归属
        func buildTree(_ index: Int) -> UUAXTreeNode {
            let raw = rawNodes[index]
            let val = raw.role == kAXStaticTextRole ? cachedValue(at: index) : nil
            let kids = raw.childIndices.map(buildTree)
            return UUAXTreeNode(role: raw.role, value: val, children: kids)
        }

        let roots = rootIndices.map(buildTree)
        return parseControllers(in: roots, truncated: truncated)
    }
}
