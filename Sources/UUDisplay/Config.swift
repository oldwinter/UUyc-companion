// 设备类型、常见分辨率预设与配置持久化
import Foundation

enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case computer, tablet, phone
    var id: String { rawValue }
    var label: String {
        switch self {
        case .computer: return "电脑"
        case .tablet: return "平板"
        case .phone: return "手机"
        }
    }
}

struct ResolutionPreset: Identifiable, Hashable {
    let category: String
    let title: String
    let width: Int
    let height: Int
    let hiDPI: Bool

    var id: String { "\(category)|\(title)|\(width)x\(height)|\(hiDPI)" }
    var sizeText: String { "\(width)×\(height)\(hiDPI ? " 高清" : "")" }
}

enum Presets {
    /// 首次配置时的类型预填：UU「电脑」组 → 电脑；名称含 Pad/平板 → 平板；其余 → 手机
    static func guessKind(name: String, isComputerGroup: Bool) -> DeviceKind {
        if isComputerGroup { return .computer }
        let lower = name.lowercased()
        return (lower.contains("pad") || lower.contains("平板")) ? .tablet : .phone
    }

    static let categories = ["折叠屏", "平板", "手机", "桌面"]

    static let all: [ResolutionPreset] = [
        // 折叠屏
        ResolutionPreset(category: "折叠屏", title: "vivo X Fold6 内屏（竖）", width: 2312, height: 2504, hiDPI: true),
        ResolutionPreset(category: "折叠屏", title: "vivo X Fold6 内屏（横）", width: 2504, height: 2312, hiDPI: true),
        ResolutionPreset(category: "折叠屏", title: "vivo X Fold6 外屏（横）", width: 2520, height: 1080, hiDPI: true),
        ResolutionPreset(category: "折叠屏", title: "OPPO Find N5 / N3 内屏（横）", width: 2480, height: 2248, hiDPI: true),
        ResolutionPreset(category: "折叠屏", title: "华为 Mate X5 / X6 内屏（横）", width: 2496, height: 2224, hiDPI: true),
        ResolutionPreset(category: "折叠屏", title: "华为 Pura X 内屏（横）", width: 2120, height: 1320, hiDPI: true),
        ResolutionPreset(category: "折叠屏", title: "荣耀 Magic V3 内屏（横）", width: 2344, height: 2156, hiDPI: true),
        // 平板
        ResolutionPreset(category: "平板", title: "iPad Air 11\" / Pro 11\"", width: 2360, height: 1640, hiDPI: true),
        ResolutionPreset(category: "平板", title: "iPad Pro 11\" (M4)", width: 2420, height: 1668, hiDPI: true),
        ResolutionPreset(category: "平板", title: "iPad Air 13\"", width: 2732, height: 2048, hiDPI: true),
        ResolutionPreset(category: "平板", title: "iPad Pro 13\" (M4)", width: 2752, height: 2064, hiDPI: true),
        ResolutionPreset(category: "平板", title: "iPad mini", width: 2266, height: 1488, hiDPI: true),
        ResolutionPreset(category: "平板", title: "OPPO Pad 3 Pro", width: 3000, height: 2120, hiDPI: true),
        // 手机
        ResolutionPreset(category: "手机", title: "iPhone 17 / 16 Pro（横）", width: 2622, height: 1206, hiDPI: true),
        ResolutionPreset(category: "手机", title: "iPhone 17 / 16 Pro Max（横）", width: 2868, height: 1320, hiDPI: true),
        ResolutionPreset(category: "手机", title: "通用手机 20:9（横）", width: 2400, height: 1080, hiDPI: true),
        // 桌面
        ResolutionPreset(category: "桌面", title: "1080p 桌面 (16:9)", width: 1920, height: 1080, hiDPI: false),
        ResolutionPreset(category: "桌面", title: "2K 桌面 (16:9)", width: 2560, height: 1440, hiDPI: false),
        ResolutionPreset(category: "桌面", title: "MacBook Air 13\"", width: 2560, height: 1664, hiDPI: true),
        ResolutionPreset(category: "桌面", title: "MacBook Pro 14\"", width: 3024, height: 1964, hiDPI: true),
        ResolutionPreset(category: "桌面", title: "带鱼屏 21:9", width: 3440, height: 1440, hiDPI: false),
        ResolutionPreset(category: "桌面", title: "4K 桌面 (16:9)", width: 3840, height: 2160, hiDPI: true),
    ]

    static func suggestedPreset(for name: String) -> ResolutionPreset? {
        let lower = name.lowercased()
        if lower.contains("fold6") || lower.contains("x fold") {
            return all.first { $0.title.contains("vivo X Fold6 内屏（竖）") }
        }
        if lower.contains("find n") { return all.first { $0.title.contains("Find N5") } }
        if lower.contains("mate x") { return all.first { $0.title.contains("Mate X5") } }
        if lower.contains("pura x") { return all.first { $0.title.contains("Pura X") } }
        if lower.contains("magic v") { return all.first { $0.title.contains("Magic V3") } }
        if lower.contains("ipad mini") { return all.first { $0.title.contains("iPad mini") } }
        if lower.contains("ipad air 13") { return all.first { $0.title.contains("iPad Air 13") } }
        if lower.contains("ipad pro 13") { return all.first { $0.title.contains("iPad Pro 13") } }
        if lower.contains("ipad pro") { return all.first { $0.title.contains("iPad Pro 11\" (M4)") } }
        if lower.contains("ipad") { return all.first { $0.title.contains("iPad Air 11") } }
        if lower.contains("pro max") { return all.first { $0.title.contains("Pro Max") } }
        if lower.contains("iphone") { return all.first { $0.title.contains("16 Pro（横）") } }
        return nil
    }

    static func typoSuggestion(width: Int, height: Int) -> (width: Int, height: Int)? {
        switch (width, height) {
        case (1980, 1080): return (1920, 1080)
        case (1080, 1980): return (1080, 1920)
        case (2560, 1400): return (2560, 1440)
        case (3840, 2100): return (3840, 2160)
        case (2360, 1600): return (2360, 1640)
        default: return nil
        }
    }
}

struct DeviceConfig: Codable, Identifiable, Hashable {
    var name: String
    var kind: DeviceKind
    /// 横屏或定制原生像素，由用户填写；0 表示还没填
    var width: Int
    var height: Int
    var hiDPI: Bool = true
    /// 从 UU「全部设备」导入时记下的分组与系统类型（用于按 UU 的样子分组、显示图标）
    var uuComputer: Bool?
    var platform: String?
    var id: String { name }
    var inComputerGroup: Bool { uuComputer ?? (kind == .computer) }

    /// 填了合理的分辨率才建虚拟屏
    var hasSize: Bool { DeviceConfig.validSize.contains(width) && DeviceConfig.validSize.contains(height) }
    static let validSize = 320...16384

    /// HiDPI 模式下将宽高对齐为偶数，确保逻辑像素 = 物理像素 / 2 无半像素缩放失真
    var effectivePixels: (width: Int, height: Int) {
        guard hiDPI else { return (width, height) }
        return (width & ~1, height & ~1)
    }

    var needsEvenAlignment: Bool {
        hiDPI && hasSize && (width % 2 != 0 || height % 2 != 0)
    }

    var isRowValidForSave: Bool {
        kind == .computer || hasSize || (width == 0 && height == 0)
    }

    var sizeLabel: String {
        let ep = effectivePixels
        return "\(ep.width)×\(ep.height)\(hiDPI ? " 高清" : "")"
    }

    static func make(name: String, kind: DeviceKind) -> DeviceConfig {
        DeviceConfig(name: name, kind: kind, width: 0, height: 0)
    }

    /// 确定性 FNV-1a 32 位序列号：同一设备名 + 像素规格 + HiDPI 始终映射同一显示器身份，避免 ColorSync ICC 无限堆积
    static func stableSerial(name: String, pixelWidth: Int, pixelHeight: Int, hiDPI: Bool, salt: UInt32 = 0) -> UInt32 {
        let input = "\(name)|\(pixelWidth)x\(pixelHeight)|\(hiDPI ? 1 : 0)"
        var hash: UInt32 = 2_166_136_261
        for byte in input.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        if salt != 0 {
            hash ^= salt &* 0x9E37_79B9
        }
        if hash == 0 || hash == UInt32.max { hash = 1 }
        return hash
    }
}

struct AppConfig: Codable {
    var devices: [DeviceConfig] = []
    var paused = false
    /// 远程时关闭物理屏（缺省关闭，在设置里开启；可选类型以兼容旧配置文件）
    var disablePhysical: Bool?
    var shouldDisablePhysical: Bool { disablePhysical ?? false }
    /// 看门狗（兜底恢复物理屏）缺省关闭，只有用户在设置里开启才安装
    var watchdogEnabled: Bool?
    var shouldRunWatchdog: Bool { watchdogEnabled ?? false }
    /// 是否已看过首次启动功能导览
    var tourShown: Bool?
    /// 可选：空闲时保持指定设备的虚拟屏就绪（改善切屏丢音频或连入黑屏瞬态；默认 nil）
    var keepWarmDevice: String?
}

final class ConfigStore {
    static let shared = ConfigStore()

    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UUDisplay", isDirectory: true)
    private let url = ConfigStore.dir.appendingPathComponent("config.json")

    var config: AppConfig {
        didSet { save() }
    }

    var isConfigured: Bool { !config.devices.isEmpty }

    private init() {
        try? FileManager.default.createDirectory(at: ConfigStore.dir, withIntermediateDirectories: true)
        config = (try? JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))) ?? AppConfig()
    }

    func device(named name: String?) -> DeviceConfig? {
        guard let name else { return nil }
        return config.devices.first { $0.name == name }
    }

    /// 合并编辑中的设备列表：有效行立即保存；正在半途输入的单行回退保留其上次已保存值，避免互相阻塞
    static func mergeValidDevices(edited: [DeviceConfig], previous: [DeviceConfig]) -> [DeviceConfig] {
        let prevMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, $0) })
        return edited.map { row in
            if row.isRowValidForSave { return row }
            if let old = prevMap[row.name] { return old }
            var cleared = row
            cleared.width = 0
            cleared.height = 0
            return cleared
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(config).write(to: url, options: .atomic)
    }
}
