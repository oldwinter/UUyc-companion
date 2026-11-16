// 菜单栏：状态 / 权限入口 / 横竖屏互换 / 切换虚拟屏规格 / 自动准备虚拟屏 / 远程时只保留虚拟屏 / 恢复 / 诊断 / 设置 / 完全退出
import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private let openSettings: (SettingsPane?) -> Void
    private let openDiagnostics: () -> Void
    private let openPermissions: () -> Void
    private let store = ConfigStore.shared
    private var manualPresetTargets: [DeviceConfig] = []

    init(coordinator: Coordinator,
         openSettings: @escaping (SettingsPane?) -> Void,
         openDiagnostics: @escaping () -> Void = {},
         openPermissions: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.openSettings = openSettings
        self.openDiagnostics = openDiagnostics
        self.openPermissions = openPermissions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    private enum IconBadge { case none, active, warning }

    private static let baseMenuBarIcon: NSImage = {
        if let image = NSImage(named: "MenuBarIconTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)!
    }()

    private static let activeMenuBarIcon: NSImage = makeBadgedIcon(badge: .active)
    private static let warningMenuBarIcon: NSImage = makeBadgedIcon(badge: .warning)

    private static func makeBadgedIcon(badge: IconBadge) -> NSImage {
        let base = baseMenuBarIcon
        guard badge != .none else { return base }
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let haloRect = NSRect(x: 11.2, y: 0.4, width: 6.4, height: 6.4)
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(ovalIn: haloRect).fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            NSColor.labelColor.setFill()
            switch badge {
            case .none:
                break
            case .active:
                NSBezierPath(ovalIn: NSRect(x: 12.2, y: 1.4, width: 4.4, height: 4.4)).fill()
            case .warning:
                NSBezierPath(ovalIn: NSRect(x: 11.7, y: 0.9, width: 5.4, height: 5.4)).fill()
                NSGraphicsContext.current?.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.clear.setFill()
                NSBezierPath(rect: NSRect(x: 14.0, y: 3.1, width: 0.85, height: 2.2)).fill()
                NSBezierPath(ovalIn: NSRect(x: 13.95, y: 1.7, width: 0.95, height: 0.95)).fill()
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func refresh() {
        let needsAttention = !UUReader.isTrusted || coordinator.display.wedged
        let icon: NSImage
        if needsAttention {
            icon = StatusBarController.warningMenuBarIcon
        } else if coordinator.connected && coordinator.display.isActive {
            icon = StatusBarController.activeMenuBarIcon
        } else {
            icon = StatusBarController.baseMenuBarIcon
        }
        icon.accessibilityDescription = "UU远程伴侣"
        item.button?.image = icon
        item.button?.appearsDisabled = store.config.paused && !needsAttention  // 暂停自动切换时图标变灰
        item.button?.toolTip = "UU远程伴侣：\(coordinator.statusText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        manualPresetTargets = []

        let status = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        let (primary, secondary) = coordinator.statusSummary
        let attr = NSMutableAttributedString(string: primary, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        if let secondary, !secondary.isEmpty {
            attr.append(NSAttributedString(string: "\n\(secondary)", attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        status.attributedTitle = attr
        status.isEnabled = false
        menu.addItem(status)

        if !UUReader.isTrusted {
            menu.addItem(action("🔑 授予辅助功能权限…", #selector(openPermissionsPanel)))
        }
        menu.addItem(.separator())

        if coordinator.canSwapOrientation {
            let swapTitle = coordinator.swappedSizeText.map { "横竖屏互换 (→ \($0))" } ?? "横竖屏互换"
            menu.addItem(action(swapTitle, #selector(swapOrientation)))
        }

        menu.addItem(buildSwitchSpecSubmenu())

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

    private func matchesActiveDisplay(_ cfg: DeviceConfig) -> Bool {
        guard coordinator.display.isActive, let current = coordinator.display.current else { return false }
        let a = current.effectivePixels
        let b = cfg.effectivePixels
        return a.width == b.width && a.height == b.height && current.hiDPI == cfg.hiDPI
    }

    private func addManualOption(to submenu: NSMenu, title: String, config: DeviceConfig, checked: Bool) {
        let idx = manualPresetTargets.count
        manualPresetTargets.append(config)
        let it = action(title, #selector(selectManualPreset(_:)))
        it.tag = idx
        it.state = checked ? .on : .off
        submenu.addItem(it)
    }

    private func headerItem(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func buildSwitchSpecSubmenu() -> NSMenuItem {
        let root = NSMenuItem(title: "切换虚拟屏规格", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let variantName = coordinator.controllerName
            ?? store.config.devices.first(where: { !Presets.variants(for: $0.name).isEmpty })?.name
        if let vName = variantName {
            let variants = Presets.variants(for: vName)
            if !variants.isEmpty {
                sub.addItem(headerItem("\(vName) 形态"))
                for preset in variants {
                    let cfg = DeviceConfig(name: vName, kind: .phone, width: preset.width, height: preset.height, hiDPI: preset.hiDPI)
                    addManualOption(to: sub, title: "\(preset.title) · \(preset.sizeText)", config: cfg, checked: matchesActiveDisplay(cfg))
                }
                sub.addItem(.separator())
            }
        }

        let configured = store.config.devices.filter { $0.hasSize }
        if !configured.isEmpty {
            sub.addItem(headerItem("已配置设备"))
            for dev in configured {
                let isCurrentAuto = coordinator.manualOverride == nil && coordinator.controllerName == dev.name && matchesActiveDisplay(dev)
                let isCurrentManual = coordinator.manualOverride?.name == dev.name && matchesActiveDisplay(dev)
                addManualOption(to: sub, title: "\(dev.name) · \(dev.sizeLabel)", config: dev, checked: isCurrentAuto || isCurrentManual)
            }
            sub.addItem(.separator())
        }

        sub.addItem(headerItem("临时常用分辨率"))
        let quickSpecs: [(String, Int, Int, Bool)] = [
            ("1080p 桌面", 1920, 1080, false),
            ("2K 桌面", 2560, 1440, false),
            ("iPad Air 11\"", 2360, 1640, true),
            ("4K 桌面", 3840, 2160, true),
        ]
        for (title, w, h, hiDPI) in quickSpecs {
            let cfg = DeviceConfig(name: title, kind: .tablet, width: w, height: h, hiDPI: hiDPI)
            let checked = coordinator.manualOverride != nil && matchesActiveDisplay(cfg)
            addManualOption(to: sub, title: "\(title) · \(cfg.sizeLabel)", config: cfg, checked: checked)
        }

        sub.addItem(.separator())
        let autoItem = action("恢复自动按设备匹配", #selector(restoreAutoMatch))
        autoItem.state = coordinator.manualOverride == nil ? .on : .off
        autoItem.isEnabled = coordinator.manualOverride != nil
        sub.addItem(autoItem)

        root.submenu = sub
        return root
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func selectManualPreset(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard manualPresetTargets.indices.contains(idx) else { return }
        coordinator.applyManualOverride(manualPresetTargets[idx])
    }

    @objc private func restoreAutoMatch() {
        coordinator.applyManualOverride(nil)
    }

    @objc private func swapOrientation() { coordinator.swapOrientation() }

    @objc private func toggleAutoVirtual() { coordinator.setPaused(!store.config.paused) }

    @objc private func toggleDisablePhysical() { coordinator.setDisablePhysical(!store.config.shouldDisablePhysical) }

    @objc private func restorePhysicalNow() { coordinator.restorePhysical() }

    @objc private func openDiagnosticsPanel() { openDiagnostics() }

    @objc private func openPermissionsPanel() { openPermissions() }

    @objc private func reconfigure() { openSettings(coordinator.preferredSettingsPane) }

    @objc private func quit() {
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}
