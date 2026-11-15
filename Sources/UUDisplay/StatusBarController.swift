// 菜单栏：状态 / 横竖屏互换 / 自动准备虚拟屏 / 远程时只保留虚拟屏 / 恢复 / 诊断 / 设置 / 完全退出
import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private let openSettings: (SettingsPane?) -> Void
    private let openDiagnostics: () -> Void
    private let store = ConfigStore.shared

    init(coordinator: Coordinator,
         openSettings: @escaping (SettingsPane?) -> Void,
         openDiagnostics: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        self.openDiagnostics = openDiagnostics
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    private static let menuBarIcon: NSImage = {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
    }()

    func refresh() {
        let icon = StatusBarController.menuBarIcon
        icon.accessibilityDescription = "UU远程伴侣"
        item.button?.image = icon
        item.button?.appearsDisabled = store.config.paused  // 暂停自动切换时图标变灰
        item.button?.toolTip = "UU远程伴侣：\(coordinator.statusText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if coordinator.canSwapOrientation {
            menu.addItem(action("横竖屏互换", #selector(swapOrientation)))
        }

        let autoVirtual = action("自动准备虚拟屏", #selector(toggleAutoVirtual))
        autoVirtual.state = store.config.paused ? .off : .on
        menu.addItem(autoVirtual)

        let physical = action("远程时只保留虚拟屏", #selector(toggleDisablePhysical))
        physical.state = store.config.shouldDisablePhysical ? .on : .off
        menu.addItem(physical)

        if coordinator.needsRecovery {
            menu.addItem(.separator())
            menu.addItem(action("⚠️ 立即恢复所有屏幕 (⌃⌥⌘9)", #selector(restorePhysicalNow)))
        }

        menu.addItem(.separator())
        menu.addItem(action("诊断与日志…", #selector(openDiagnosticsPanel)))
        menu.addItem(action("设置…", #selector(reconfigure), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("完全退出", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func swapOrientation() { coordinator.swapOrientation() }

    @objc private func toggleAutoVirtual() { coordinator.setPaused(!store.config.paused) }

    @objc private func toggleDisablePhysical() { coordinator.setDisablePhysical(!store.config.shouldDisablePhysical) }

    @objc private func restorePhysicalNow() { coordinator.restorePhysical() }

    @objc private func openDiagnosticsPanel() { openDiagnostics() }

    @objc private func reconfigure() { openSettings(nil) }

    @objc private func quit() {
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}
