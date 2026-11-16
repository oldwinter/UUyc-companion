// 设备配置面板（设置窗口第一栏）：只列出从 UU「全部设备」导入的设备，为平板/手机/折叠屏填写虚拟屏分辨率，改动按行独立自动保存
import AppKit
import SwiftUI

final class WizardModel: ObservableObject {
    @Published var rows: [DeviceConfig] = [] {
        didSet { if !loading { scheduleSave() } }
    }
    @Published var message: String?
    @Published var trusted = UUReader.isTrusted
    @Published var refreshing = false
    @Published var collapsedComputers = false
    @Published var collapsedMobiles = false

    /// 自动保存后回调（设置窗口借此重新应用配置、显示「已自动保存」）
    var onSaved: (() -> Void)?

    private let store = ConfigStore.shared
    private var loading = false
    private var saveWork: DispatchWorkItem?

    init() {
        loading = true
        trusted = UUReader.isTrusted
        rows = store.config.devices
        loading = false
        if rows.isEmpty && trusted {
            refreshFromUU()
        } else if !trusted {
            message = "需要先完成授权，才能自动从 UU远程 读取设备列表。"
        }
    }

    var computers: [Binding<DeviceConfig>] { bindings { $0.inComputerGroup } }
    var mobiles: [Binding<DeviceConfig>] { bindings { !$0.inComputerGroup } }

    private func bindings(_ keep: @escaping (DeviceConfig) -> Bool) -> [Binding<DeviceConfig>] {
        rows.filter(keep).map { row in
            Binding(get: { [weak self] in self?.rows.first { $0.name == row.name } ?? row },
                    set: { [weak self] new in
                        guard let self, let i = self.rows.firstIndex(where: { $0.name == row.name }) else { return }
                        self.rows[i] = new
                    })
        }
    }

    /// 兼容旧调用点；统一改为后台异步刷新，绝不阻塞主线程
    func load() {
        refreshFromUU()
    }

    func openUUMainWindow() {
        guard trusted else {
            message = "需要先完成授权，才能唤醒 UU远程 主界面。"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            UUReader.showMainWindow()
        }
    }

    /// 从 UU远程「全部设备」异步导入；保留已配置的自定义分辨率并按行自动保存
    func refreshFromUU() {
        trusted = UUReader.isTrusted
        guard trusted else {
            message = "需要先完成授权，才能读到 UU远程 里的设备。授权后点「从 UU远程 刷新设备」。"
            return
        }
        guard !refreshing else { return }
        refreshing = true
        message = "正在从 UU远程 后台读取设备列表…"

        let currentRows = rows
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if !UUReader.hasMainWindow {
                UUReader.showMainWindow()
                Thread.sleep(forTimeInterval: 1.0)
            }
            let found = (UUReader.readDevices() ?? []).filter { !$0.isSelf }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshing = false
                self.trusted = UUReader.isTrusted
                guard !found.isEmpty else {
                    self.message = "没有读到设备列表。请打开 UU远程，点击「全部设备」页面后再点「从 UU远程 刷新设备」。"
                    return
                }
                let merged: [DeviceConfig] = found.map { d in
                    let existing = currentRows.first { $0.name == d.name } ?? self.store.device(named: d.name)
                    var cfg = existing
                        ?? DeviceConfig.make(name: d.name, kind: Presets.guessKind(name: d.name, isComputerGroup: d.isComputerGroup))
                    cfg.uuComputer = d.isComputerGroup
                    cfg.platform = d.platform
                    return cfg
                }
                self.loading = true
                self.rows = merged
                self.loading = false
                self.message = "已从 UU远程 同步 \(found.count) 台设备（不含这台 Mac），并已自动保存。"
                self.save()
            }
        }
    }

    /// 输入分辨率时逐字触发，稍等再保存，避免按半截数字建虚拟屏
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func save() {
        saveWork?.cancel()
        let validMerged = ConfigStore.mergeValidDevices(edited: rows, previous: store.config.devices)
        store.config.devices = validMerged
        onSaved?()
    }
}

// MARK: - UU 风格的设备图标

/// 简笔安卓机器人（SF Symbols 没有安卓图标）
struct AndroidGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 18
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            var head = Path()
            head.addArc(center: p(9, 8), radius: 6 * s, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            head.closeSubpath()
            ctx.fill(head, with: .color(.white))
            var antenna = Path()
            antenna.move(to: p(5.6, 3.6)); antenna.addLine(to: p(4.2, 1.4))
            antenna.move(to: p(12.4, 3.6)); antenna.addLine(to: p(13.8, 1.4))
            ctx.stroke(antenna, with: .color(.white), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
            for x in [6.6, 11.4] as [CGFloat] {
                ctx.fill(Path(ellipseIn: CGRect(origin: p(x - 0.8, 4.9), size: CGSize(width: 1.6 * s, height: 1.6 * s))), with: .color(.accentColor))
            }
            ctx.fill(Path(roundedRect: CGRect(origin: p(3, 9), size: CGSize(width: 12 * s, height: 7.5 * s)), cornerRadius: 1.8 * s), with: .color(.white))
        }
    }
}

struct DeviceIcon: View {
    let cfg: DeviceConfig

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.accentColor)
            .frame(width: 34, height: 34)
            .overlay(glyph.foregroundStyle(.white))
    }

    @ViewBuilder private var glyph: some View {
        switch cfg.platform ?? "" {
        case "macos", "ios": Image(systemName: "apple.logo").font(.system(size: 17, weight: .medium))
        case "android": AndroidGlyph().frame(width: 20, height: 20)
        case "win", "windows": Image(systemName: "square.grid.2x2.fill").font(.system(size: 15))
        default: Image(systemName: cfg.inComputerGroup ? "desktopcomputer" : "ipad.and.iphone").font(.system(size: 15))
        }
    }
}

// MARK: - 设备卡片

struct DeviceRow: View {
    @Binding var cfg: DeviceConfig

    /// 两档：不指定（由 UU 决定）/ 自定义分辨率；切换时保留所属分组，不意外跳组
    private var customBinding: Binding<Bool> {
        Binding(get: { cfg.kind != .computer }, set: { custom in
            if cfg.uuComputer == nil {
                cfg.uuComputer = (cfg.kind == .computer)
            }
            if custom {
                cfg.kind = Presets.guessKind(name: cfg.name, isComputerGroup: false)
            } else {
                cfg.kind = .computer
            }
        })
    }

    /// 0 显示为空（显示灰字「宽」「高」）
    private func sizeBinding(_ key: WritableKeyPath<DeviceConfig, Int>) -> Binding<Int?> {
        Binding(get: { cfg[keyPath: key] == 0 ? nil : cfg[keyPath: key] }, set: { cfg[keyPath: key] = $0 ?? 0 })
    }

    private func applyPreset(_ preset: ResolutionPreset) {
        cfg.width = preset.width
        cfg.height = preset.height
        cfg.hiDPI = preset.hiDPI
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                DeviceIcon(cfg: cfg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if cfg.kind != .computer {
                        if cfg.hasSize {
                            Text(cfg.detailSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text("待填写分辨率").font(.caption).foregroundStyle(.orange).lineLimit(1)
                        }
                    } else if cfg.hasSize {
                        Text("不指定（已保留 \(cfg.width)×\(cfg.height)）").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

                Picker("", selection: customBinding) {
                    Text("不指定").tag(false)
                    Text("自定义").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 126)

                if cfg.kind == .computer {
                    Text("不指定，由 UU远程 决定")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 298, alignment: .leading)
                } else {
                    HStack(spacing: 6) {
                        TextField("宽", value: sizeBinding(\.width), format: .number.grouping(.never))
                            .frame(width: 56).multilineTextAlignment(.trailing)
                        Text("×").foregroundStyle(.secondary)
                        TextField("高", value: sizeBinding(\.height), format: .number.grouping(.never))
                            .frame(width: 56)

                        Button {
                            let oldW = cfg.width
                            cfg.width = cfg.height
                            cfg.height = oldW
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .help("交换横竖屏宽高")
                        .disabled(cfg.width == 0 && cfg.height == 0)

                        Menu("预设") {
                            if let suggested = Presets.suggestedPreset(for: cfg.name) {
                                Button("推荐：\(suggested.title) (\(suggested.sizeText))") { applyPreset(suggested) }
                                Divider()
                            }
                            ForEach(Presets.categories, id: \.self) { category in
                                let items = Presets.all.filter { $0.category == category }
                                Menu(category) {
                                    ForEach(items) { preset in
                                        Button("\(preset.title) (\(preset.sizeText))") {
                                            applyPreset(preset)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 64)

                        Toggle("HiDPI", isOn: $cfg.hiDPI)
                            .help("高清视网膜缩放：开启后物理像素倍增、文字更清晰")
                    }
                    .frame(width: 298, alignment: .leading)
                }
            }

            if cfg.kind != .computer {
                if !cfg.hasSize, let suggested = Presets.suggestedPreset(for: cfg.name) {
                    Button {
                        applyPreset(suggested)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("检测到匹配预设：点此一键填入 \(suggested.title)（\(suggested.sizeText)）")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                    .padding(.leading, 44)
                } else if let typo = Presets.typoSuggestion(width: cfg.width, height: cfg.height) {
                    Button {
                        cfg.width = typo.width
                        cfg.height = typo.height
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                            Text("疑似误输 \(cfg.width)×\(cfg.height)，点此一键修正为 \(typo.width)×\(typo.height)")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.orange)
                    .padding(.leading, 44)
                } else if cfg.needsEvenAlignment {
                    let aligned = cfg.effectivePixels
                    Text("提示：HiDPI 模式下奇数像素将自动对齐为偶数（实际生成 \(aligned.width)×\(aligned.height)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 44)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 54)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08)))
    }
}

/// 仿 UU「全部设备」的分组标题：⌄ 电脑 3
struct DeviceGroupHeader: View {
    let title: String
    let count: Int
    @Binding var collapsed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text("\(count)").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

struct WizardView: View {
    @ObservedObject var model: WizardModel
    var openPermissions: (() -> Void)?
    /// 嵌入设置窗口时使用面板标题与自适应宽度
    var embedded = false
    var savedHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("为 UU远程 中已登录的设备指定虚拟屏分辨率").font(.title2.bold())
                Spacer()
                if savedHint { Label("已自动保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Button(model.refreshing ? "正在读取…" : "从 UU远程 刷新设备") { model.refreshFromUU() }
                    .disabled(model.refreshing)
            }
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
            if !model.trusted {
                Button("去授权…") { openPermissions?() }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let computers = model.computers
                    let mobiles = model.mobiles
                    if computers.isEmpty && mobiles.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "ipad.and.iphone")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("暂无已同步的设备")
                                .font(.headline)
                            Text("请先在 UU远程 登录设备并切换到「全部设备」页面，然后点击下方刷新按钮。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                            HStack(spacing: 10) {
                                Button("唤醒 UU远程 主界面") { model.openUUMainWindow() }
                                    .disabled(!model.trusted)
                                Button(model.refreshing ? "正在读取…" : "从 UU远程 刷新设备") { model.refreshFromUU() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.refreshing || !model.trusted)
                            }
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                    } else {
                        if !computers.isEmpty {
                            DeviceGroupHeader(title: "电脑", count: computers.count, collapsed: $model.collapsedComputers)
                            if !model.collapsedComputers {
                                Text("💻 通常保持「不指定」即可；若从 Windows / Mac 远控无头 Mac 遇到分辨率过低或比例黑边，也可切为「自定义」指定 1080p / 2K / HiDPI 虚拟屏。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(computers, id: \.wrappedValue.id) { DeviceRow(cfg: $0) }
                            }
                        }
                        if !mobiles.isEmpty {
                            DeviceGroupHeader(title: "手机/平板", count: mobiles.count, collapsed: $model.collapsedMobiles)
                            if !model.collapsedMobiles {
                                Text("💡 可从每行右侧「预设」菜单直接选择常见手机、折叠屏与 iPad 分辨率，或点 ⇄ 一键切换横竖屏。")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(mobiles, id: \.wrappedValue.id) { DeviceRow(cfg: $0) }
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minHeight: 220)
        }
        .padding(embedded ? 18 : 20)
        .frame(minWidth: embedded ? nil : 820, minHeight: embedded ? nil : 460)
    }
}
