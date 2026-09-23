#!/bin/bash
# build-app.sh —— 编译菜单栏 App 并组装 .app bundle
#
# 产出 build/DisplayLab.app
# 无第三方依赖，只要 Xcode Command Line Tools。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/DisplayLabMenu/DisplayLabMenuApp.swift"
APP="$ROOT/build/DisplayLab.app"
BUNDLE_ID="com.displaylab.menu"
VERSION="0.1.0"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# 0. 图标（若还没生成 icns，先从 PNG 生成一次）
if [ ! -f "$ROOT/App/DisplayLab.icns" ]; then
    swift "$ROOT/App/generate-icon.swift" "$ROOT/App/DisplayLab.png"
    mkdir -p /tmp/DisplayLab.iconset
    for s in 16 32 64 128 256 512; do
        sips -z $s $s "$ROOT/App/DisplayLab.png" --out "/tmp/DisplayLab.iconset/icon_${s}x${s}.png" >/dev/null
    done
    for s in 32 64 128 256 512 1024; do
        half=$((s/2))
        sips -z $s $s "$ROOT/App/DisplayLab.png" --out "/tmp/DisplayLab.iconset/icon_${half}x${half}@2x.png" >/dev/null
    done
    iconutil -c icns /tmp/DisplayLab.iconset -o "$ROOT/App/DisplayLab.icns"
fi
cp "$ROOT/App/DisplayLab.icns" "$APP/Contents/Resources/AppIcon.icns"

# 1. 编译
swiftc -O -parse-as-library \
    -framework SwiftUI -framework AppKit -framework CoreGraphics \
    -o "$APP/Contents/MacOS/DisplayLab" \
    "$SRC"

# 2. Info.plist
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DisplayLab</string>
    <key>CFBundleDisplayName</key>
    <string>DisplayLab</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>DisplayLab</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF

# 3. adhoc 签名（避免"已损坏"提示，首次运行仍可能需右键打开）
codesign --force --sign - "$APP" 2>/dev/null || true

echo "已生成：$APP"
echo "运行：open $APP   （首次运行若被拦，右键 → 打开）"
