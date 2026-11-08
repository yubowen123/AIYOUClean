#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release --product AIYOUClean --jobs 4
swift build -c release --product aiyouclean-cli --jobs 4
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/AIYOUClean-0.6.2.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/AIYOUClean" "$APP_DIR/Contents/MacOS/AIYOUClean"
cp "$BIN_DIR/aiyouclean-cli" "$PROJECT_DIR/dist/aiyouclean-cli-0.6.2"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AIYOUClean</string>
<key>CFBundleDisplayName</key><string>AIYOUClean</string>
<key>CFBundleIdentifier</key><string>local.aiyou.AIYOUClean</string>
<key>CFBundleExecutable</key><string>AIYOUClean</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.2</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSDesktopFolderUsageDescription</key><string>扫描您选择的桌面文件，帮助查找大文件和重复文件。</string>
<key>NSDocumentsFolderUsageDescription</key><string>扫描您选择的文稿目录，帮助查找大文件和重复文件。</string>
<key>NSDownloadsFolderUsageDescription</key><string>扫描下载文件，显示可由您确认后移到废纸篓的项目。</string>
<key>NSNetworkVolumesUsageDescription</key><string>扫描您选择的网络卷中的文件。</string>
<key>NSRemovableVolumesUsageDescription</key><string>扫描您选择的外接卷中的文件。</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Independent implementation. Not affiliated with MacPaw.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf '%s\n' "$APP_DIR"
