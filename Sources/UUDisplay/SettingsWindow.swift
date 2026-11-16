// 设置窗口（上中下结构）
// 上：工作原理图「控制端 ⇢ 被控 Mac ⇢ 兜底」，点各自按钮向下展开对应面板（同一时间只展开一个）
// 中：立即恢复所有屏幕 / 权限设置 / 功能导览
// 下：关于本应用 / 完全退出（右对齐）
import AppKit
import ServiceManagement
import SwiftUI
import SystemSettingsKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case controller, controlled, fallback
    var id: String { rawValue }
}

final class SettingsModel: ObservableObject {
    // 注意：SwiftUI 的 @State 在仅有 Command Line Tools 时无法编译（宏插件缺失），界面状态统一放在 ObservableObject 里
    @Published var expanded: SettingsPane?
    @Published var autoVirtual: Bool
    @Published var disablePhysical: Bool
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var watchdogEnabled: Bool
    @Published var watchdogRunning = Watchdog.isRunning
    @Published var physicalOff = PhysicalDisplays.pending != nil
    @Published var axGranted = UUReader.isTrusted
    @Published var hasConflict = false
    @Published var savedHint = false
    @Published var quickStartShown = false
    @Published var keepWarmDevice = ""

    let devices = WizardModel()
    var onConfigChanged: (() -> Void)?
    var onPaneChanged: ((SettingsPane?) -> Void)?
    var onWatchdogEnabled: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var restorePhysical: (() -> Void)?
    var openPermissions: (() -> Void)?
    var openDiagnostics: (() -> Void)?
    var openTour: (() -> Void)?
    private var timer: Timer?
    private let store = ConfigStore.shared

    init() {
        autoVirtual = !store.config.paused
        disablePhysical = store.config.shouldDisablePhysical
        watchdogEnabled = store.config.shouldRunWatchdog
        keepWarmDevice = store.config.keepWarmDevice ?? ""
        devices.onSaved = { [weak self] in self?.devicesSaved() }
    }

    var keepWarmCandidates: [DeviceConfig] {
        devices.rows.filter { $0.kind != .computer && $0.hasSize }
    }

    func setKeepWarmDevice(_ name: String) {
        keepWarmDevice = name
        store.config.keepWarmDevice = name.isEmpty ? nil : name
        Log.info("设置：空闲时保持虚拟屏就绪 → \(name.isEmpty ? "关" : name)")
        onConfigChanged?()
    }

    var fallbackAvailable: Bool { autoVirtual && disablePhysical }

    var headerStatusText: String {
        if !axGranted { return "未授予辅助功能权限，暂无法自动识别控制端设备" }
        if !autoVirtual { return "自动准备虚拟屏已暂停" }
        if physicalOff { return "当前处于仅虚拟屏模式 · 按 ⌃⌥⌘9 可立即恢复所有屏幕" }
        if !keepWarmDevice.isEmpty { return "待机保活已启用：\(keepWarmDevice)" }
        return "待机运行中 · 连入设备后将自动匹配虚拟屏"
    }

    func start() {
        refresh()
        checkConflictAsync()
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.4
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func checkConflictAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let conflict = Diagnostics.hasConflictingAdapter()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hasConflict != conflict else { return }
                self.hasConflict = conflict
            }
        }
    }

    func refresh() {
        let running = Watchdog.isRunning
        if running != watchdogRunning { watchdogRunning = running }
        let off = PhysicalDisplays.pending != nil
        if off != physicalOff { physicalOff = off }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
        let ax = UUReader.isTrusted
        if ax != axGranted {
            axGranted = ax
            devices.trusted = ax
        }
    }

    /// 点同一个按钮再次收起；兜底面板只在开启软关闭后可展开
    func toggle(_ pane: SettingsPane) {
        if pane == .fallback && !fallbackAvailable { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
            expanded = expanded == pane ? nil : pane
        }
        onPaneChanged?(expanded)
    }

    /// 设备列表自动保存后：按新配置重新应用，并短暂显示「已自动保存」
    func devicesSaved() {
        if !keepWarmDevice.isEmpty {
            let stillValid = store.config.devices.contains {
                $0.name == keepWarmDevice && $0.kind != .computer && $0.hasSize
            }
            if !stillValid {
                keepWarmDevice = ""
                store.config.keepWarmDevice = nil
            }
        }
        onConfigChanged?()
        savedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.savedHint = false }
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "开机启动没有设置成功：\(error.localizedDescription)。请先把本应用放进「应用程序」文件夹，再试一次。"
            Log.info("⚠️ 开机启动设置失败：\(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func toggleAutoVirtual(_ on: Bool) {
        autoVirtual = on
        setPaused?(!on)
        Log.info("设置：自动启动虚拟屏 → \(on ? "开" : "关")")
        if !fallbackAvailable && expanded == .fallback {
            withAnimation { expanded = nil }
            onPaneChanged?(nil)
        }
    }

    func toggleDisablePhysical(_ on: Bool) {
        disablePhysical = on
        setDisablePhysical?(on)
        Log.info("设置：自动软关闭物理屏 → \(on ? "开" : "关")")
        if !on && expanded == .fallback {
            withAnimation { expanded = nil }
            onPaneChanged?(nil)
        }
    }

    /// 只有在这里开启，看门狗才会安装为 LaunchAgent 并加载；关闭即卸载
    func toggleWatchdog(_ on: Bool) {
        watchdogEnabled = on
        store.config.watchdogEnabled = on
        Log.info("设置：看门狗 → \(on ? "开" : "关")")
        if on {
            onWatchdogEnabled?()
            WatchdogAgent.ensureInstalled()
        } else {
            WatchdogAgent.uninstall()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    func showAbout() { AboutPage.show() }

    /// 完全退出：停掉本次登录中的看门狗（不卸载，下次打开 App 或重新登录时恢复），再退出主程序
    func quitCompletely() {
        Log.info("完全退出：停止看门狗并退出主程序")
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}

// MARK: - 快捷键示意图（⌃ ⌥ ⌘ 9 四个键）

private struct HotkeyCap: View {
    let symbol: String
    var name: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 2)
            .overlay(
                VStack(spacing: 2) {
                    Text(symbol).font(.system(size: name == nil ? 28 : 24, weight: .semibold))
                    if let name { Text(name).font(.system(size: 11, weight: .medium)) }
                }
                .foregroundStyle(.white)
            )
            .frame(width: name == nil ? 64 : 78, height: 64)
    }
}

struct HotkeyKeysView: View {
    var body: some View {
        HStack(spacing: 10) {
            HotkeyCap(symbol: "⌃", name: "control")
            plus
            HotkeyCap(symbol: "⌥", name: "option")
            plus
            HotkeyCap(symbol: "⌘", name: "command")
            plus
            HotkeyCap(symbol: "9")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("快捷键：同时按下 control、option、command 和 9")
    }

    private var plus: some View {
        Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.secondary)
    }
}

// MARK: - 面板

private struct Card<Content: View>: View {
    let icon: String
    let title: String
    let tag: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
                Text(title).font(.headline)
                Text(tag).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - 工作原理图

/// 虚线箭头，中间带说明文字；纵向对齐到图标中线
private struct DashedConnector: View {
    let label: String
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 5))
                        p.addLine(to: CGPoint(x: w - 8, y: 5))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))
                    Path { p in
                        p.move(to: CGPoint(x: w - 10, y: 0))
                        p.addLine(to: CGPoint(x: w, y: 5))
                        p.addLine(to: CGPoint(x: w - 10, y: 10))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 10)
        }
        .padding(.top, compact ? 10 : 30)
        .frame(minWidth: 70, maxWidth: .infinity)
    }
}

/// 控制端图标：平板 + 手机 组合
private struct ControllerIcon: View {
    var compact = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "ipad.landscape")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: compact ? 44 : 92)
                .offset(x: compact ? -3 : -6, y: compact ? -5 : -10)
            Image(systemName: "iphone")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(height: compact ? 26 : 52)
                .padding(compact ? 2 : 4)
                .background(RoundedRectangle(cornerRadius: compact ? 6 : 10).fill(Color(nsColor: .windowBackgroundColor)))
        }
        .frame(width: compact ? 52 : 108, height: compact ? 42 : 96)
    }
}

private struct FlowNode<Icon: View>: View {
    let caption: String
    let buttonTitle: String
    var enabled = true
    var selected = false
    var compact = false
    var hint: String? = nil
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: compact ? 5 : 8) {
            icon()
                .font(.system(size: compact ? 34 : 76, weight: .light))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: compact ? 52 : 108, height: compact ? 42 : 96)
            Text(caption)
                .font((compact ? Font.caption : Font.subheadline).weight(.medium))
                .foregroundStyle(enabled ? .primary : .secondary)
            Group {
                if selected {
                    Button(action: action) { Label(buttonTitle, systemImage: "chevron.up") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: action) { Label(buttonTitle, systemImage: "chevron.down") }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(compact ? .regular : .large)
            .disabled(!enabled)
            .help(hint ?? "")
        }
        .frame(width: 180)
    }
}

// MARK: - 展开面板

/// 被控制端：开机启动 / 自动启动虚拟屏 / 自动软关闭物理屏
struct ControlledPanel: View {
    @ObservedObject var model: SettingsModel

    private func row(_ title: String, _ detail: String, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(enabled ? .primary : .secondary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().disabled(!enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("被控端设置").font(.title3.bold())
            row("开机启动",
                "待机时轻量常驻，内存占用约 20MB。",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
            if let err = model.loginError {
                Text(err).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            row("自动准备虚拟屏",
                "远程开始时自动准备名为\"UUyc Companion\"的虚拟屏，供平板或手机使用；在 UU远程 选择此屏幕即可获得无黑边的高清画面，远程结束时自动移除。",
                isOn: Binding(get: { model.autoVirtual }, set: { model.toggleAutoVirtual($0) }))
            Divider()
            row("远程时关闭除虚拟屏之外的所有屏幕",
                "若不想手工选择虚拟屏，或希望远程时所有窗口与 Dock 只停留在虚拟屏中，请打开此功能；远程结束时自动恢复。\n若担心恢复失败，可在「恢复兜底」中开启守护助手。",
                isOn: Binding(get: { model.disablePhysical }, set: { model.toggleDisablePhysical($0) }),
                enabled: model.autoVirtual)
            if !model.autoVirtual {
                Text("要先打开「自动准备虚拟屏」。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("空闲时保持虚拟屏就绪（防切屏丢声）")
                        .font(.headline)
                        .foregroundStyle(model.autoVirtual ? .primary : .secondary)
                    Text("未在远控时保留一块虚拟屏，避免无显示器 Mac mini 切屏瞬间桌面乱飞或音频输出丢失；待机期间不关闭物理屏，且不阻止屏幕休眠。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: Binding(
                    get: { model.keepWarmDevice },
                    set: { model.setKeepWarmDevice($0) }
                )) {
                    Text("关闭").tag("")
                    ForEach(model.keepWarmCandidates, id: \.name) { dev in
                        Text("\(dev.name) (\(dev.sizeLabel))").tag(dev.name)
                    }
                    if !model.keepWarmDevice.isEmpty
                        && !model.keepWarmCandidates.contains(where: { $0.name == model.keepWarmDevice }) {
                        Text("\(model.keepWarmDevice)（分辨率待完善）").tag(model.keepWarmDevice)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .disabled(!model.autoVirtual || (model.keepWarmCandidates.isEmpty && model.keepWarmDevice.isEmpty))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 兜底选项：快捷键 + 看门狗
struct FallbackPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("恢复兜底").font(.title3.bold())
                Text("远程结束时，虚拟屏之外的屏幕会自动恢复。万一失败，请用下面的方法兜底找回。").foregroundStyle(.secondary)
            }

            Card(icon: "keyboard", title: "快捷键人肉兜底", tag: "随时可用") {
                Text("有人在本机前时、同时按下 **⌃ control + ⌥ option + ⌘ command + 9**，所有屏幕会立刻恢复，远程不受影响。")
                    .fixedSize(horizontal: false, vertical: true)
                HotkeyKeysView()
                Text("若没人在本机前，再次远程本机，点设置窗口的「立即恢复所有屏幕」，效果一样。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Card(icon: "shield.lefthalf.filled", title: "守护助手", tag: "可选") {
                Text("打开后，守护助手会在后台每 5 秒检查所有屏幕。遇到下面任一情况，它会自动把屏幕点亮：")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("• 本程序 崩溃或意外退出")
                    Text("• 本程序 卡住超过 10 秒没响应")
                    Text("• 远程已经断开，但屏幕却没亮")
                }
                .font(.callout)
                Text("守护助手若自身意外退出，会在 5 秒内恢复。")
                    .font(.callout).foregroundStyle(.secondary)

                Divider()
                Text("需要你允许的事").font(.subheadline.bold())
                Text("守护助手打开后，macOS 会提示「UUDisplayWatchdog已添加后台项目」，占用内存3MB。守护助手无需其他权限；关掉此处开关就会被彻底移除。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { model.watchdogEnabled }, set: { model.toggleWatchdog($0) })) {
                        Text("打开守护助手")
                    }
                    .toggleStyle(.switch)
                    if model.watchdogEnabled {
                        Label(model.watchdogRunning ? "正在值守" : "没有运行",
                              systemImage: model.watchdogRunning ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.watchdogRunning ? .green : .orange)
                        if !model.watchdogRunning {
                            Button("去系统设置里允许") { SystemSettings.open(.loginItems) }
                        }
                    }
                }
            }

            if !model.watchdogEnabled {
                Label("若本程序意外退出，远程结束时被关闭的屏幕不会自动恢复。",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 快速上手

private struct QuickStartView: View {
    private let steps = [
        "在要用于远程的平板、手机、电脑和本机上登录同一个 UU远程 账号，本软件会自动读取设备列表。",
        "在「控制端设置」中直接选用内置预设（含手机、折叠屏、iPad、桌面）或手动填入设备物理像素分辨率；点 ⇄ 可随时切换横竖屏。",
        "开启「自动准备虚拟屏」后，远程连入时将自动生成名为 \"UUyc Companion\" 的高清虚拟屏；也可在菜单栏「切换虚拟屏规格」中临时切屏。",
        "若不想手动切屏，或希望彻底避免窗口和 Dock 乱跑，可打开「远程时关闭除虚拟屏之外的所有屏幕」（建议搭配守护助手）。",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快速上手").font(.headline)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}

// MARK: - 整体

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// 离屏渲染时展开内容不放进 ScrollView（便于检查完整排版）
    var forRender = false

    private var isExpanded: Bool { model.expanded != nil }

    @ViewBuilder private var expandedContent: some View {
        switch model.expanded {
        case .controller:
            WizardView(model: model.devices, openPermissions: model.openPermissions, embedded: true,
                       savedHint: model.savedHint)
                .frame(height: 450)
        case .controlled:
            ControlledPanel(model: model)
        case .fallback:
            if forRender {
                FallbackPanel(model: model)
            } else {
                ScrollView { FallbackPanel(model: model) }.frame(height: 450)
            }
        case .none:
            EmptyView()
        }
    }

    private var statusBadgeColor: Color {
        if !model.axGranted { return .orange }
        if !model.autoVirtual { return .secondary }
        if model.physicalOff { return .blue }
        return .green
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部实时运行状态条
            HStack(spacing: 8) {
                Circle().fill(statusBadgeColor).frame(width: 8, height: 8)
                Text(model.headerStatusText)
                    .font(.caption)
                    .foregroundStyle(model.axGranted ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !model.axGranted {
                    Button("去授权") { model.openPermissions?() }
                        .buttonStyle(.link)
                        .font(.caption.weight(.medium))
                }
                if model.hasConflict {
                    Button {
                        model.openDiagnostics?()
                    } label: {
                        Label("发现冲突服务 · 查看", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.orange)
                    .font(.caption.weight(.medium))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03))

            Divider()

            // 上：工作原理图
            HStack(alignment: .top, spacing: 0) {
                FlowNode(caption: "用于远程的设备", buttonTitle: "控制端设置",
                         selected: model.expanded == .controller, compact: isExpanded,
                         action: { model.toggle(.controller) }) {
                    ControllerIcon(compact: isExpanded)
                }
                DashedConnector(label: "使用 UU远程 远程操控", compact: isExpanded)
                FlowNode(caption: "本机", buttonTitle: "设置被控端",
                         selected: model.expanded == .controlled, compact: isExpanded,
                         action: { model.toggle(.controlled) }) {
                    Image(systemName: "desktopcomputer")
                }
                DashedConnector(label: "只保留虚拟屏时", compact: isExpanded)
                FlowNode(caption: "万一物理屏没恢复", buttonTitle: "恢复兜底",
                         enabled: model.fallbackAvailable, selected: model.expanded == .fallback, compact: isExpanded,
                         hint: model.fallbackAvailable ? nil : "先在「设置被控端」里打开「远程时关闭除虚拟屏之外的所有屏幕」",
                         action: { model.toggle(.fallback) }) {
                    Image(systemName: "lifepreserver")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, isExpanded ? 12 : 20)
            .padding(.bottom, isExpanded ? 10 : 16)

            if model.expanded != nil {
                expandedContent
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // 中：常用操作
            HStack(spacing: 12) {
                Button { model.restorePhysical?() } label: {
                    Label("立即恢复所有屏幕", systemImage: "display.2")
                }
                .disabled(!model.physicalOff)
                .help(model.physicalOff ? "也可以按 ⌃ control + ⌥ option + ⌘ command + 9" : "现在没有熄灭的屏幕")
                Button { model.openPermissions?() } label: { Label("权限设置", systemImage: "hand.raised") }
                Button { model.openDiagnostics?() } label: { Label("诊断", systemImage: "stethoscope") }
                Button { model.openTour?() } label: { Label("功能介绍", systemImage: "sparkles") }
                Button { model.quickStartShown.toggle() } label: { Label("快速上手", systemImage: "list.number") }
                    .popover(isPresented: $model.quickStartShown, arrowEdge: .bottom) { QuickStartView() }
            }
            .controlSize(.large)
            .padding(.vertical, 14)

            Divider()

            // 下：关于 / 完全退出
            HStack(spacing: 10) {
                Spacer()
                Button("关于 UU远程伴侣") { model.showAbout() }
                Button("完全退出", role: .destructive) { model.quitCompletely() }
                    .help("关闭 UU远程伴侣，守护助手也会一起停下（下次打开时恢复）")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 820)
        .clipped()
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    /// 自测用：当前设置窗口的模型与窗口
    var currentModel: SettingsModel? { model }
    var currentWindow: NSWindow? { window }
    var openPermissions: (() -> Void)?
    var openDiagnostics: (() -> Void)?
    var openTour: (() -> Void)?
    var onConfigChanged: (() -> Void)?
    var onPaneChanged: ((SettingsPane?) -> Void)?
    var onWatchdogEnabled: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var restorePhysical: (() -> Void)?

    private func clampToVisibleScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = window.frame.origin
        if window.frame.maxY > visible.maxY {
            origin.y = max(visible.minY, visible.maxY - window.frame.height)
        }
        if origin.y < visible.minY {
            origin.y = visible.minY
        }
        if origin != window.frame.origin {
            window.setFrameOrigin(origin)
        }
    }

    /// - Parameter pane: 打开时展开的面板，nil 表示全部收起
    func show(pane: SettingsPane? = nil) {
        if let window, let model {
            if let pane, model.expanded != pane { model.toggle(pane) }
            clampToVisibleScreen(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsModel()
        model.expanded = (pane == .fallback && !model.fallbackAvailable) ? nil : pane
        model.onConfigChanged = onConfigChanged
        model.onPaneChanged = onPaneChanged
        model.onWatchdogEnabled = onWatchdogEnabled
        model.setDisablePhysical = setDisablePhysical
        model.setPaused = setPaused
        model.restorePhysical = restorePhysical
        model.openPermissions = openPermissions
        model.openDiagnostics = openDiagnostics
        model.openTour = openTour
        model.start()
        self.model = model
        // 用 NSHostingController 作为内容控制器：窗口尺寸随 SwiftUI 内容（展开/收起）自动调整。
        // 注意：直接给 NSHostingView 设 sizingOptions = .preferredContentSize 会让窗口初始尺寸为 0×0（看不见）
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = "设置"
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)  // 先定好尺寸再居中，否则按 0×0 居中会偏到右侧
        w.center()
        clampToVisibleScreen(w)
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self, weak w] _ in
            guard let w else { return }
            self?.clampToVisibleScreen(w)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.model?.stop()
            self?.model = nil
            self?.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染各状态为 PNG（--render-settings <目录>）
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases: [(String, SettingsPane?, Bool, Bool)] = [
            ("collapsed-physical-off", nil, false, false),
            ("collapsed-physical-on", nil, true, false),
            ("controller", .controller, false, false),
            ("controlled", .controlled, true, false),
            ("fallback", .fallback, true, true),
        ]
        for (name, pane, physical, watchdog) in cases {
            let model = SettingsModel()
            model.autoVirtual = true
            model.disablePhysical = physical
            model.watchdogEnabled = watchdog
            model.watchdogRunning = false
            model.expanded = pane
            let view = NSHostingView(rootView: SettingsView(model: model, forRender: true))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-\(name).png"))
            }
        }
    }
}
