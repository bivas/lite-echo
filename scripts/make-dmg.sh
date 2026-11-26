#!/usr/bin/env bash
# Packages build/LiteEcho.app into build/LiteEcho-<version>.dmg (+ .sha256, + .zip of the app).
#
#   LITEECHO_VERSION=1.2.3 scripts/make-dmg.sh     (default: version stamped in the app)
#
# Layout: LiteEcho.app, an /Applications symlink, a volume icon, and a generated background
# (scripts/make-dmg-background.swift) with the icons positioned over it via a Finder
# AppleScript. Set LITEECHO_DMG_PLAIN=1 to skip the background/layout. If Finder scripting
# fails (e.g. no GUI session) a plain DMG is produced with a warning; the build never fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/LiteEcho.app"
[[ -d "$APP" ]] || { echo "missing $APP; run scripts/build-app.sh --release first" >&2; exit 1; }

VERSION="${LITEECHO_VERSION:-}"
VERSION="${VERSION#v}"
[[ -n "$VERSION" ]] || VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLNAME="LiteEcho $VERSION"
DMG="$BUILD/LiteEcho-$VERSION.dmg"
ZIP="$BUILD/LiteEcho-$VERSION.zip"
BG_DIR="$ROOT/app/Assets"
PLAIN="${LITEECHO_DMG_PLAIN:-0}"
ICON="$ROOT/app/Assets/AppIcon.icns"

STAGE="$(mktemp -d)"
RW="$BUILD/.rw-$VERSION.dmg"
MNT=""
trap '[[ -n "$MNT" ]] && hdiutil detach "$MNT" -force >/dev/null 2>&1; rm -rf "$STAGE" "$RW"' EXIT

echo "==> Staging"
mkdir -p "$STAGE/src"
ditto "$APP" "$STAGE/src/LiteEcho.app"
ln -s /Applications "$STAGE/src/Applications"
if [[ "$PLAIN" != "1" ]]; then
    echo "==> Rendering background"
    if swift "$ROOT/scripts/make-dmg-background.swift" "$BG_DIR" >/dev/null; then
        mkdir "$STAGE/src/.background"
        cp "$BG_DIR/dmg-background.tiff" "$STAGE/src/.background/background.tiff"
    else
        echo "warning: could not render DMG background; using plain layout" >&2
        PLAIN=1
    fi
fi

echo "==> Creating $DMG"
rm -f "$DMG" "$RW" "$DMG.sha256" "$ZIP" "$ZIP.sha256"
SIZE_MB=$(( $(du -sm "$STAGE/src" | cut -f1) + 40 ))
hdiutil create -quiet -srcfolder "$STAGE/src" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" "$RW"

# Mounted under /Volumes (browsable) so Finder can script the disk by name.
MNT="$(hdiutil attach -noverify -noautoopen -readwrite "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}' | head -1)"
[[ -d "$MNT" ]] || { echo "could not mount $RW" >&2; exit 1; }

# Volume icon (shows on the mounted disk and the .dmg file icon in Finder).
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$MNT/.VolumeIcon.icns"
    SetFile -a C "$MNT" 2>/dev/null || xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" "$MNT" 2>/dev/null || true
fi

# Finder layout: 780x400 content (bounds are 32 pt taller for the title bar), icon view, 128 px icons, background picture, icon centres
# at (214,214) and (564,214). Finder writes it to .DS_Store on the volume.
if [[ "$PLAIN" != "1" ]]; then
    echo "==> Applying Finder layout"
    if osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    try
      set sidebar width of container window to 0
    end try
    set the bounds of container window to {200, 120, 980, 552}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "LiteEcho.app" of container window to {214, 214}
    set position of item "Applications" of container window to {564, 214}
    update without registering applications
    delay 3
    close
    open
    delay 2
    set the bounds of container window to {200, 120, 980, 552}
    update without registering applications
    delay 5
  end tell
end tell
OSA
    then
        # Wait for Finder to flush .DS_Store.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            [[ -s "$MNT/.DS_Store" ]] && break
            sleep 1
        done
        [[ -s "$MNT/.DS_Store" ]] || echo "warning: Finder wrote no .DS_Store; DMG layout may be plain" >&2
        osascript -e "tell application \"Finder\" to close (every window whose name is \"$VOLNAME\")" >/dev/null 2>&1 || true
        sleep 2
    else
        echo "warning: Finder layout failed; continuing with plain layout" >&2
    fi
fi

sync
hdiutil detach -quiet "$MNT" || { sleep 3; hdiutil detach -quiet -force "$MNT"; }
MNT=""

# ULFO (LZFSE) is smaller and faster than UDZO but needs macOS 10.11+; fine for macOS 14+.
hdiutil convert -quiet "$RW" -format ULFO -o "$DMG"
rm -f "$RW"

echo "==> Zip of the app"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Checksums"
( cd "$BUILD" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" \
    && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

echo "Built $DMG ($(du -h "$DMG" | cut -f1)), $ZIP ($(du -h "$ZIP" | cut -f1))"
