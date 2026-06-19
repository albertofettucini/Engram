#!/bin/bash
# Builds Engram.app (with the glossy white "E" icon) and drops it on the Desktop.
# Run from anywhere:  bash packaging/make-app.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"

# 1) icon → 1024 master → .icns
swift "$HERE/make-icon.swift" "$WORK/icon_1024.png"
ICS="$WORK/AppIcon.iconset"; mkdir -p "$ICS"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$ICS/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$WORK/icon_1024.png" --out "$ICS/icon_${s}x${s}@2x.png" >/dev/null
done
cp "$WORK/icon_1024.png" "$ICS/icon_512x512@2x.png"
iconutil -c icns "$ICS" -o "$WORK/AppIcon.icns"

# 2) build the app binary (release)
cd "$ROOT"
swift build -c release --product engram-app

# 3) assemble the .app bundle
APP="$WORK/Engram.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp ".build/release/engram-app" "$APP/Contents/MacOS/Engram"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 3b) embed Sparkle (the app links it for in-app updates). Copy the framework + its nested
# XPC services/helpers, and add the bundle Frameworks dir to the binary's rpath (the SPM rpath
# points at the build dir, which is gone at runtime).
cp -R ".build/release/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Engram" 2>/dev/null || true

# 4) ad-hoc sign. Strip the xattrs codesign rejects ("resource fork … detritus"), then sign
# inside-out: Sparkle's XPC services / Autoupdate / Updater.app, then the framework, the main
# binary, and finally the app (no --deep — it mis-signs Sparkle's nested helpers).
xattr -cr "$APP"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for c in "$SPK/XPCServices/"*.xpc "$SPK/Autoupdate" "$SPK/Updater.app"; do
  [ -e "$c" ] && codesign --force --sign - "$c"
done
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP/Contents/MacOS/Engram"
codesign --force --sign - "$APP"

# 5) place on the Desktop
rm -rf "$HOME/Desktop/Engram.app"
cp -R "$APP" "$HOME/Desktop/Engram.app"
rm -rf "$WORK"
echo "✅ Engram.app → $HOME/Desktop/Engram.app"
