#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_dir/.build/AI TRMNL.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/ai-trmnl" "$app_dir/Contents/MacOS/ai-trmnl"
cp -R "$binary_dir/AITrmnl_TRMNLCore.bundle" "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.brianpattison.ai-trmnl</string>
  <key>CFBundleName</key><string>AI TRMNL</string>
  <key>CFBundleExecutable</key><string>ai-trmnl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>AI TRMNL serves display images to your TRMNL devices on your home network.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_dir"
printf 'Built %s\nLaunch with: open "%s"\n' "$app_dir" "$app_dir"
