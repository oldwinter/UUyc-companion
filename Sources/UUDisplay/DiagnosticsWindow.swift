// 诊断与日志面板 + CLI（--diagnose）：一键排查虚拟屏残留、头less占位屏、ICC膨胀、权限与冲突后台进程
import AppKit
import CoreGraphics
import Foundation
import SwiftUI

struct DiagnosticSnapshot {
    let conflicts: [String]
    let iccURLs: [URL]
    let hasMarkers: Bool
    let report: String

    var hasConflict: Bool { !conflicts.isEmpty }
    var iccCount: Int { iccURLs.count }
}

enum Diagnostics {
    static let colorSyncDisplaysDir = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays")
    static let conflictingLaunchAgentLabel = "com.oldwinter.uu-display-adapter"
    static let iccCleanupCommand = "sudo rm -f '/Library/ColorSync/Profiles/Displays/UUyc companion-'*.icc"

    static var conflictingLaunchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(conflictingLaunchAgentLabel).plist")
    }

    static func conflictingAdapters() -> [String] {
        var found: [String] = []
        let agentPlist = conflictingLaunchAgentPlistURL
        if FileManager.default.fileExists(atPath: agentPlist.path) {
            found.append("LaunchAgent 配置：\(agentPlist.path)")
        }

        let uid = getuid()
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["print", "gui/\(uid)/\(conflictingLaunchAgentLabel)"]
        launchctl.standardOutput = FileHandle.nullDevice
        launchctl.standardError = FileHandle.nullDevice
        if (try? launchctl.run()) != nil {
            launchctl.waitUntilExit()
            if launchctl.terminationStatus == 0 {
                found.append("运行中的 LaunchAgent 服务：gui/\(uid)/\(conflictingLaunchAgentLabel)")
            }
        }

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-fl", "uu-display|UUDisplayAdapter"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        if (try? pgrep.run()) != nil {
            pgrep.waitUntilExit()
            if pgrep.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                for line in text.split(separator: "\n") {
                    found.append("运行中进程：\(line)")
                }
            }
        }
        return found
    }

    static func hasConflictingAdapter() -> Bool {
        !conflictingAdapters().isEmpty
    }

    /// 停用旧版冲突 LaunchAgent（由用户点击诊断面板按钮后触发）
    static func bootoutConflictingAdapter() -> (success: Bool, message: String) {
        let uid = getuid()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(uid)/\(conflictingLaunchAgentLabel)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                Log.info("已停用旧版冲突服务：\(conflictingLaunchAgentLabel)")
                return (true, "已停用旧版显示适配服务 \(conflictingLaunchAgentLabel)。")
            }
            return (false, "launchctl bootout 返回 \(p.terminationStatus)，可能该服务已停止或需要手动移除配置。")
        } catch {
            return (false, "停用失败：\(error.localizedDescription)")
        }
    }

    static func iccProfileURLs() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: colorSyncDisplaysDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter {
            $0.pathExtension.lowercased() == "icc"
                && $0.lastPathComponent.lowercased().contains("uuyc companion")
        }
    }

    static func iccProfileCount() -> Int {
        iccProfileURLs().count
    }

    private static func readLogTail(maxLines: Int = 20) -> [String] {
        guard let text = try? String(contentsOf: Log.fileURL, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines).map(String.init))
    }

    static func collectSnapshot() -> DiagnosticSnapshot {
        var lines: [String] = []
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let buildPath = Bundle.main.bundlePath
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let config = ConfigStore.shared.config

        lines.append("=== UU远程伴侣 诊断报告 ===")
        lines.append("时间：\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("版本：\(version)  路径：\(buildPath)")
        lines.append("系统：\(os)")
        lines.append("")

        lines.append("[连接与权限]")
        lines.append("  辅助功能权限（AXIsProcessTrusted）：\(UUReader.isTrusted ? "已授权" : "未授权")")
        lines.append("  UU远程 主程序进程：\(UUReader.app.map { "运行中 (pid=\($0.processIdentifier))" } ?? "未运行")")
        lines.append("  UURemoteServer 覆盖窗口：\(UUMonitor.overlayPresent() ? "有" : "无")")
        lines.append("  UURemoteServer 防息屏断言：\(UUPowerAssertion.uuServerHasDisplayAssertion() ? "活跃" : "无")")
        lines.append("  物理屏私有控制 API：\(PhysicalDisplays.available ? "可用" : "不可用")")
        lines.append("  自动准备虚拟屏：\(!config.paused ? "开" : "关")")
        lines.append("  远程时软关闭物理屏：\(config.shouldDisablePhysical ? "开" : "关")")
        lines.append("  待机保活设备：\(config.keepWarmDevice ?? "未启用")")
        lines.append("  守护助手（Watchdog）：启用=\(config.shouldRunWatchdog ? "是" : "否"), Loaded=\(WatchdogAgent.isLoaded ? "是" : "否"), Running=\(Watchdog.isRunning ? "是" : "否")")
        lines.append("")

        lines.append("[当前在线显示器]")
        let ids = DisplayManager.onlineDisplays()
        if ids.isEmpty {
            lines.append("  (无在线显示器)")
        } else {
            for id in ids {
                let active = CGDisplayIsActive(id) != 0 ? "active" : "inactive"
                let asleep = CGDisplayIsAsleep(id) != 0 ? ", asleep" : ""
                let builtin = CGDisplayIsBuiltin(id) != 0 ? ", builtin" : ""
                let vendor = String(format: "0x%04X", CGDisplayVendorNumber(id))
                let model = String(format: "0x%04X", CGDisplayModelNumber(id))
                let serial = String(format: "0x%08X", CGDisplaySerialNumber(id))
                let pxW = CGDisplayPixelsWide(id)
                let pxH = CGDisplayPixelsHigh(id)
                let bounds = CGDisplayBounds(id)
                let tag: String
                if PhysicalDisplays.isVirtual(id) {
                    tag = "虚拟屏"
                } else if PhysicalDisplays.isHeadlessPlaceholder(id) {
                    tag = "macOS 无头占位屏（不纳入禁用）"
                } else {
                    tag = "物理屏"
                }
                lines.append("  #\(id) [\(tag)] \(pxW)×\(pxH)px (logical \(Int(bounds.width))×\(Int(bounds.height))) \(active)\(asleep)\(builtin) vendor=\(vendor) model=\(model) serial=\(serial)")
            }
        }
        lines.append("")

        lines.append("[残留标记与状态文件]")
        let pending = PhysicalDisplays.pending
        lines.append("  disabled-displays.json：\(pending.map { "\($0)" } ?? "无")")
        let sessionURL = ConfigStore.dir.appendingPathComponent("session.json")
        let sessionExists = FileManager.default.fileExists(atPath: sessionURL.path)
        if let rawSession = try? String(contentsOf: sessionURL, encoding: .utf8) {
            lines.append("  session.json：\(rawSession.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            lines.append("  session.json：无")
        }
        lines.append("")

        lines.append("[环境冲突与 ColorSync 检查]")
        let conflicts = conflictingAdapters()
        if conflicts.isEmpty {
            lines.append("  竞品/旧版显示适配服务：未发现冲突")
        } else {
            lines.append("  ⚠️ 发现可能冲突的旧版显示适配服务：")
            conflicts.forEach { lines.append("    - \($0)") }
            lines.append("    停用命令：launchctl bootout gui/\(getuid())/\(conflictingLaunchAgentLabel)")
        }
        let iccURLs = iccProfileURLs()
        let iccCount = iccURLs.count
        lines.append("  ColorSync UUyc companion ICC 文件数：\(iccCount)\(iccCount > 3 ? "（偏多，建议清理历史残留）" : "")")
        if iccCount > 3 {
            lines.append("  清理命令（退出 App 后执行）：\(iccCleanupCommand)")
        }
        lines.append("")

        lines.append("[最近日志尾部 (\(Log.fileURL.path))]")
        let tail = readLogTail(maxLines: 20)
        if tail.isEmpty {
            lines.append("  (日志文件为空或不存在)")
        } else {
            tail.forEach { lines.append("  \($0)") }
        }
        return DiagnosticSnapshot(
            conflicts: conflicts,
            iccURLs: iccURLs,
            hasMarkers: pending != nil || sessionExists,
            report: lines.joined(separator: "\n")
        )
    }

    static func generateReport() -> String {
        collectSnapshot().report
    }
}

final class DiagnosticsModel: ObservableObject {
    @Published var report = ""
    @Published var hasConflict = false
    @Published var iccCount = 0
    @Published var hasMarkers = false
    @Published var isRefreshing = false
    @Published var copiedHint = false
    @Published var copiedText = "已复制报告"
    @Published var actionMessage: String?

    var onClearMarkers: (() -> Void)?
    private var refreshGeneration = 0

    func refresh() {
        refreshGeneration += 1
        let gen = refreshGeneration
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snap = Diagnostics.collectSnapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.refreshGeneration == gen else { return }
                self.isRefreshing = false
                self.hasConflict = snap.hasConflict
                self.iccCount = snap.iccCount
                self.hasMarkers = snap.hasMarkers
                self.report = snap.report
            }
        }
    }

    func copyReport() {
        copyToPasteboard(report, label: "已复制报告")
    }

    func copyICCCleanCommand() {
        copyToPasteboard(Diagnostics.iccCleanupCommand, label: "已复制命令")
    }

    private func copyToPasteboard(_ content: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copiedText = label
        copiedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copiedHint = false }
    }

    func openLog() {
        if FileManager.default.fileExists(atPath: Log.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
        } else {
            NSWorkspace.shared.open(Log.fileURL.deletingLastPathComponent())
        }
    }

    func openColorSyncDir() {
        NSWorkspace.shared.open(Diagnostics.colorSyncDisplaysDir)
    }

    func revealConflictPlist() {
        let url = Diagnostics.conflictingLaunchAgentPlistURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func stopConflictingAdapter() {
        isRefreshing = true
        actionMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = Diagnostics.bootoutConflictingAdapter()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.actionMessage = res.message
                self.refresh()
            }
        }
    }

    func clearMarkers() {
        onClearMarkers?()
        refresh()
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("诊断与日志").font(.title2.bold())
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if model.copiedHint {
                    Label(model.copiedText, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button("刷新") { model.refresh() }.disabled(model.isRefreshing)
                Button("复制报告") { model.copyReport() }.disabled(model.report.isEmpty)
                Button("打开日志文件") { model.openLog() }
                if model.hasMarkers {
                    Button("清理残留恢复标记") { model.clearMarkers() }
                }
            }

            if let msg = model.actionMessage {
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            if model.hasConflict {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("检测到旧版 `uu-display-adapter` 正同时运行，可能与 UU远程伴侣 争抢显示器配置。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("在访达中定位") { model.revealConflictPlist() }
                    Button("一键停用冲突服务") { model.stopConflictingAdapter() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRefreshing)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            if model.iccCount > 3 {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text("系统 ColorSync 目录存在 \(model.iccCount) 个 `UUyc companion` 描述文件（新版已固定序列号避免继续增长）。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("打开目录") { model.openColorSyncDir() }
                    Button("复制清理命令") { model.copyICCCleanCommand() }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
            }

            ScrollView {
                Text(model.report.isEmpty ? "正在后台采集诊断信息…" : model.report)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
        }
        .padding(20)
        .frame(width: 740, height: 540)
        .onAppear { model.refresh() }
    }
}

final class DiagnosticsWindowController {
    private var window: NSWindow?
    private var model: DiagnosticsModel?
    var onClearMarkers: (() -> Void)?

    func show() {
        if let window {
            model?.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = DiagnosticsModel()
        model.onClearMarkers = onClearMarkers
        model.refresh()
        self.model = model
        let hosting = NSHostingController(rootView: DiagnosticsView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "诊断与日志"
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.model = nil
            self?.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
