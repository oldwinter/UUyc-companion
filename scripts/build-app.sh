#!/bin/zsh
# 构建「UUyc companion.app」（中文系统显示为「UU远程伴侣」）。
# 用法：scripts/build-app.sh [--install]
# 内部标识保持不变：Bundle ID com.corndog.uudisplay（辅助功能授权按它识别）、
# 可执行文件 UUDisplay / UUDisplayWatchdog、配置目录与日志文件名
# 签名策略：优先使用环境变量 SIGN_IDENTITY；未指定时依次查找 "UUDisplay Signing"、"Apple Development"，
# 若钥匙串中均无有效证书，自动降级为 ad-hoc 签名（SIGN_IDENTITY=-）。
# --install：复制到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.4.0"
APP_NAME="UUyc companion"
APP="build/$APP_NAME.app"
LEGACY_APP="/Applications/UUDisplay.app"   # 改名前的安装位置

if [[ -z "${SIGN_IDENTITY+x}" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if echo "$IDENTITIES" | grep -q '"UUDisplay Signing"'; then
    SIGN_IDENTITY="UUDisplay Signing"
  elif echo "$IDENTITIES" | grep -q '"Apple Development'; then
    SIGN_IDENTITY="$(echo "$IDENTITIES" | grep -m1 '"Apple Development' | sed -E 's/.*"([^"]+)".*/\1/')"
  else
    SIGN_IDENTITY="-"
    echo "ℹ️ 未检测到开发签名证书，自动采用 ad-hoc 签名（重新构建后需在系统设置中重新授权辅助功能）"
  fi
fi

if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$SIGN_IDENTITY\""; then
  echo "❌ 钥匙串中找不到有效的代码签名证书「$SIGN_IDENTITY」；没有证书可用 SIGN_IDENTITY=- 改为 ad-hoc 签名" >&2
  exit 1
fi

swift build -c release --product UUDisplay
BIN="$(swift build -c release --show-bin-path)/UUDisplay"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UUDisplay"
# 看门狗用独立文件名，避免 killall/pkill UUDisplay 时连同看门狗一起结束
cp "$BIN" "$APP/Contents/MacOS/UUDisplayWatchdog"
# PermissionFlow 资源包（本地化文案等），放 Contents/Resources 供 PermissionFlowResources 查找
cp -R "$(dirname "$BIN")/PermissionFlow_PermissionFlow.bundle" "$APP/Contents/Resources/"
# 功能导览配图（TourKit 从 Bundle.main 的 Resources 根目录按文件名查找）
cp Assets/Tour/*.png "$APP/Contents/Resources/"
# App 图标与菜单栏模板图（见 Assets/AppIcon/README.md）
cp Assets/AppIcon/AppIcon.icns Assets/AppIcon/MenuBarIconTemplate.png Assets/AppIcon/MenuBarIconTemplate@2x.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.corndog.uudisplay</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleName</key><string>UUyc companion</string>
  <key>CFBundleDisplayName</key><string>UUyc companion</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>UUDisplay</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# 看门狗 LaunchAgent 由 App 运行时写入 ~/Library/LaunchAgents 并用 launchctl 加载（见 WatchdogAgent）
# 本地化名称：中文系统显示「UU远程伴侣」，其他语言显示「UUyc companion」
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
printf '"CFBundleDisplayName" = "UU远程伴侣";\n"CFBundleName" = "UU远程伴侣";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "UUyc companion";\n"CFBundleName" = "UUyc companion";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"

# 先签内嵌的看门狗可执行文件，再签整个 App
codesign --force --sign "$SIGN_IDENTITY" --identifier com.corndog.uudisplay.watchdog "$APP/Contents/MacOS/UUDisplayWatchdog"
codesign --force --sign "$SIGN_IDENTITY" --identifier com.corndog.uudisplay "$APP"
codesign --verify --strict --deep "$APP"
echo "✅ 已生成 $APP（签名：$SIGN_IDENTITY）"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x UUDisplay 2>/dev/null && sleep 1 || true
  pkill -x UUDisplayWatchdog 2>/dev/null || true
  rm -rf "$LEGACY_APP" "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✅ 已安装到 /Applications 并启动"
fi
