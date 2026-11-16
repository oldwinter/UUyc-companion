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

        // 5. 逻辑像素摘要、方向文案、折叠屏多形态变体与新增误输/预设匹配
        precondition(evenHiDPI.logicalSize == (1156, 1252))
        precondition(evenHiDPI.orientationLabel == "竖屏")
        precondition(evenHiDPI.detailSummary == "逻辑 1156×1252 pt · 竖屏")

        let landscapeDev = DeviceConfig(name: "iPad Air", kind: .tablet, width: 2360, height: 1640, hiDPI: true)
        precondition(landscapeDev.logicalSize == (1180, 820))
        precondition(landscapeDev.orientationLabel == "横屏")

        let squareDev = DeviceConfig(name: "Square", kind: .tablet, width: 2000, height: 2000, hiDPI: false)
        precondition(squareDev.logicalSize == (2000, 2000))
        precondition(squareDev.orientationLabel == "方屏")

        let foldVariants = Presets.variants(for: "vivo X Fold6")
        precondition(foldVariants.count == 4, "vivo X Fold6 应提供内外横竖 4 种预设形态")
        precondition(foldVariants.contains { $0.width == 1080 && $0.height == 2520 })
        precondition(Presets.variants(for: "OPPO Find N5").count == 2)

        let typo3 = Presets.typoSuggestion(width: 2560, height: 1660)
        precondition(typo3?.width == 2560 && typo3?.height == 1664)
        let typo4 = Presets.typoSuggestion(width: 1920, height: 1280)
        precondition(typo4?.width == 1920 && typo4?.height == 1200)
        precondition(Presets.suggestedPreset(for: "MacBook Pro 16")?.width == 3456)
        precondition(Presets.suggestedPreset(for: "home win11")?.width == 1920)
        precondition(Presets.suggestedPreset(for: "Xiaomi Pad 7")?.width == 3200)

        print("PASS: Config effectivePixels, presets/typos, per-row merge save, stable FNV-1a serial, variants & detailSummary")
    }
}
