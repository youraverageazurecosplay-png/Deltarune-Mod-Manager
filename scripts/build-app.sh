#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Deltarune Mod Manager.app"
PKG="$ROOT/Deltarune Mod Manager.pkg"
ICONSET="$ROOT/.build/AppIcon-UserAsset.iconset"
ICON_PNG="$ROOT/Sources/DeltaruneModManager/Resources/app-icon.png"
LAUNCHER_TEMPLATE="$ROOT/.build/DesktopModLauncher.app"

cd "$ROOT"
swift build -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
cp "$ROOT/.build/release/DeltaruneModManager" "$APP/Contents/MacOS/DeltaruneModManager"
mkdir -p "$LAUNCHER_TEMPLATE/Contents/MacOS" "$LAUNCHER_TEMPLATE/Contents/Resources"
swiftc -parse-as-library -O "$ROOT/scripts/desktop-mod-launcher.swift" \
    -o "$LAUNCHER_TEMPLATE/Contents/MacOS/DesktopModLauncher"
cat > "$LAUNCHER_TEMPLATE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DELTARUNE Mod Launcher</string>
    <key>CFBundleDisplayName</key>
    <string>DELTARUNE Mod Launcher</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.deltarune-mod-manager.desktop-launcher</string>
    <key>CFBundleExecutable</key>
    <string>DesktopModLauncher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
cp "$ICON_PNG" "$LAUNCHER_TEMPLATE/Contents/Resources/AppIcon.png"
plutil -lint "$LAUNCHER_TEMPLATE/Contents/Info.plist"
rm -rf "$APP/Contents/Resources/DesktopModLauncher.app"
ditto "$LAUNCHER_TEMPLATE" "$APP/Contents/Resources/DesktopModLauncher.app"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Sources/DeltaruneModManager/Resources/title-background.png" \
    "$APP/Contents/Resources/title-background.png"
cp "$ROOT/scripts/drmt" "$APP/Contents/Resources/drmt"
rm -f "$APP/Contents/Resources/undertale-background.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DELTARUNE Mod Manager</string>
    <key>CFBundleDisplayName</key>
    <string>DELTARUNE Mod Manager</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.deltarune-mod-manager</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.6</string>
    <key>CFBundleVersion</key>
    <string>7</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>DeltaruneModManager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>DELTARUNE Mod Manager Instance Launch</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>dmt</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleURLName</key>
            <string>GameBanana G3M One-Click Install</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>g3m</string>
                <string>deltahub</string>
            </array>
        </dict>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
printf 'Built: %s\n' "$APP"

pkgbuild \
    --component "$APP" \
    --install-location /Applications \
    --identifier com.local.deltarune-mod-manager \
    --version 1.0.6 \
    "$PKG"

printf 'Built installer: %s\n' "$PKG"
