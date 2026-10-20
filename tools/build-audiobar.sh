#!/bin/bash
# 编译 AudioBar.app
#
#   bash tools/build-audiobar.sh              只编译到 ./AudioBar.app
#   bash tools/build-audiobar.sh --install    编译并复制到 /Applications
#
# 依赖：Xcode 命令行工具（swiftc / codesign）
#
# alc-verb 是可选的：它是 AppleALC 的附带工具，用来给前置麦克风补偏置电压。
# 没有它 App 也能正常切换设备，只是「麦克风偏置」这一项不生效。
#   · 有 AppleALC 源码：ALC_VERB=/path/to/AppleALC/build/Release/alc-verb
#   · 或把任意可用的 alc-verb 放到 PATH / 用上面的环境变量指过去
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/AudioBar.app"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

command -v swiftc >/dev/null 2>&1 || {
  echo "缺 swiftc，请先装 Xcode 命令行工具：xcode-select --install"; exit 1; }

echo "== 1. 清理 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== 2. 编译 =="
swiftc -O -o "$APP/Contents/MacOS/AudioSwitch" "$ROOT/src/main.swift" -framework Cocoa

echo "== 3. 组装 bundle =="
cp "$ROOT/src/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/icon/AppIcon.icns" ] && cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/"

# alc-verb（可选）
ALC="${ALC_VERB:-}"
if [ -z "$ALC" ]; then
  for c in "$ROOT/../AppleALC/build/Release/alc-verb" "$(command -v alc-verb || true)"; do
    [ -x "$c" ] && ALC="$c" && break
  done
fi
if [ -n "$ALC" ] && [ -x "$ALC" ]; then
  cp "$ALC" "$APP/Contents/Resources/alc-verb"
  echo "   已打包 alc-verb：$ALC"
else
  echo "   ⚠️ 未找到 alc-verb（麦克风偏置功能将不生效）"
  echo "      指定方式：ALC_VERB=/path/to/alc-verb bash tools/build-audiobar.sh"
fi

chmod +x "$APP/Contents/MacOS/AudioSwitch"
[ -f "$APP/Contents/Resources/alc-verb" ] && chmod +x "$APP/Contents/Resources/alc-verb"

echo "== 4. ad-hoc 签名 =="
codesign --force --deep -s - "$APP"

echo "== 5. 结果 =="
printf "   %s\n" "$APP"
printf "   版本 %s · %s\n" \
  "$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)" \
  "$(/usr/bin/du -sh "$APP" | /usr/bin/cut -f1)"

if [ "$INSTALL" = "1" ]; then
  echo "== 6. 部署 =="
  rm -rf /Applications/AudioBar.app
  cp -R "$APP" /Applications/
  echo "   已安装 /Applications/AudioBar.app"
fi
