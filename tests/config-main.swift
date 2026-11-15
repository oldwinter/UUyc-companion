import Foundation

@main struct ConfigTests {
    static func main() {
        // 1. HiDPI 奇数像素偶数对齐，避免半像素缩放失真
        let oddHiDPI = DeviceConfig(name: "Test Phone", kind: .phone, width: 2313, height: 2505, hiDPI: true)
        precondition(oddHiDPI.needsEvenAlignment)
        precondition(oddHiDPI.effectivePixels.width == 2312)
        precondition(oddHiDPI.effectivePixels.height == 2504)
        precondition(oddHiDPI.sizeLabel == "2312×2504 高清")

        let oddNonHiDPI = DeviceConfig(name: "Test Monitor", kind: .tablet, width: 2313, height: 2505, hiDPI: false)
        precondition(!oddNonHiDPI.needsEvenAlignment)
        precondition(oddNonHiDPI.effectivePixels.width == 2313)
        precondition(oddNonHiDPI.effectivePixels.height == 2505)

        let evenHiDPI = DeviceConfig(name: "vivo X Fold6", kind: .phone, width: 2312, height: 2504, hiDPI: true)
        precondition(!evenHiDPI.needsEvenAlignment)
        precondition(evenHiDPI.effectivePixels == (2312, 2504))

        // 2. 常见误输提示与设备预设匹配
        let typo1 = Presets.typoSuggestion(width: 1980, height: 1080)
        precondition(typo1?.width == 1920 && typo1?.height == 1080)
        let typo2 = Presets.typoSuggestion(width: 2560, height: 1400)
        precondition(typo2?.width == 2560 && typo2?.height == 1440)
        precondition(Presets.typoSuggestion(width: 1920, height: 1080) == nil)

        let foldPreset = Presets.suggestedPreset(for: "vivo X Fold6")
        precondition(foldPreset?.width == 2312 && foldPreset?.height == 2504 && foldPreset?.hiDPI == true)

        // 3. 按行独立保存：某一行正在输入半截数字（无效），另一行的合法修改仍能正常保存
        let prev = [
            DeviceConfig(name: "iPad", kind: .tablet, width: 2360, height: 1640, hiDPI: true),
            DeviceConfig(name: "Phone", kind: .phone, width: 2400, height: 1080, hiDPI: true),
        ]
        let edited = [
            DeviceConfig(name: "iPad", kind: .tablet, width: 19, height: 0, hiDPI: true),      // 半截输入，无效
            DeviceConfig(name: "Phone", kind: .phone, width: 2312, height: 2504, hiDPI: false), // 合法修改
        ]
        let merged = ConfigStore.mergeValidDevices(edited: edited, previous: prev)
        precondition(merged[0].width == 2360 && merged[0].height == 1640, "半截无效行应回退保留旧配置")
        precondition(merged[1].width == 2312 && merged[1].height == 2504 && merged[1].hiDPI == false, "另一行合法改动必须独立生效")

        // 4. FNV-1a 序列号稳定性（同一设备同规格始终映射到固定 serial，防止 ColorSync ICC 无限生成）
        let s1 = DeviceConfig.stableSerial(name: "vivo X Fold6", pixelWidth: 2312, pixelHeight: 2504, hiDPI: true)
        let s2 = DeviceConfig.stableSerial(name: "vivo X Fold6", pixelWidth: 2312, pixelHeight: 2504, hiDPI: true)
        let s3 = DeviceConfig.stableSerial(name: "vivo X Fold6", pixelWidth: 2504, pixelHeight: 2312, hiDPI: true)
        let s4 = DeviceConfig.stableSerial(name: "vivo X Fold6", pixelWidth: 2312, pixelHeight: 2504, hiDPI: false)
        let s5 = DeviceConfig.stableSerial(name: "vivo X Fold6", pixelWidth: 2312, pixelHeight: 2504, hiDPI: true, salt: 1)
        precondition(s1 == s2 && s1 != 0 && s1 != UInt32.max)
        precondition(s1 != s3 && s1 != s4 && s1 != s5)

        print("PASS: Config effectivePixels, presets/typos, per-row merge save, stable FNV-1a serial")
    }
}
