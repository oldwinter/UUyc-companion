// 「关于」窗口：原生 SwiftUI + AppKit 实现，无外部私有依赖
import AppKit
import SwiftUI

private struct AboutCredit: Identifiable {
    let name: String
    let url: String
    let author: String
    let license: String
    let usage: String
    var id: String { name }
}

private struct AboutView: View {
    private static let credits: [AboutCredit] = [
        AboutCredit(name: "FreeDisplay", url: "https://github.com/huberdf/FreeDisplay",
                    author: "huberdf", license: "MIT", usage: "虚拟屏接口声明"),
        AboutCredit(name: "PermissionFlow", url: "https://github.com/jaywcjlove/PermissionFlow",
                    author: "小弟调调（jaywcjlove）", license: "MIT", usage: "授权引导"),
        AboutCredit(name: "TourKit", url: "https://github.com/rampatra/TourKit",
                    author: "Ram Patra（rampatra）", license: "MIT", usage: "功能介绍页"),
    ]

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.0"
    }

    private var appIcon: NSImage {
        if let icon = NSApp?.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil) ?? NSImage()
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            VStack(spacing: 4) {
                Text("UU远程伴侣（UUyc companion）")
                    .font(.title2.bold())
                Text("版本 \(appVersion)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("改善 Mac 版 UU远程 的使用体验，自动提供与控制端设备同分辨率的 HiDPI 虚拟屏幕，告别上下黑边与无头分辨率困局。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if let forkURL = URL(string: "https://github.com/oldwinter/UUyc-companion") {
                    Link("项目主页", destination: forkURL)
                }
                Text("·").foregroundStyle(.tertiary)
                if let upstreamURL = URL(string: "https://github.com/aoyamashou/UUyc-companion") {
                    Link("上游原版 (AoyamaShou)", destination: upstreamURL)
                }
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("致谢开源组件").font(.subheadline.bold())
                ForEach(AboutView.credits) { c in
                    HStack(spacing: 6) {
                        if let u = URL(string: c.url) {
                            Link(c.name, destination: u).font(.callout.weight(.medium))
                        } else {
                            Text(c.name).font(.callout.weight(.medium))
                        }
                        Text("(\(c.license)) · \(c.author) — \(c.usage)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("免责与隐私：完全本地运行，不联网、不收集任何数据。本应用与网易 UU远程 及其开发商没有任何直接、间接或连带关系。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 440)
    }
}

enum AboutPage {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: AboutView())
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = "关于 UU远程伴侣"
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染为 PNG（--render-about <文件>）
    static func render(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let view = NSHostingView(rootView: AboutView())
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    static func setUpDebugLabels() {
        // 已移除私有 AboutKit 依赖，保留入口兼容
    }
}
