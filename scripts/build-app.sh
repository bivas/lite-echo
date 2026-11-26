#!/usr/bin/env bash
# Builds build/LiteEcho.app with the Command Line Tools only (no Xcode).
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --debug    debug build (faster)
#   LITEECHO_VERSION=1.2.3 scripts/build-app.sh    stamp a version (also: --version 1.2.3);
#                                   defaults to the version in pyproject.toml
#
# Signing: ad-hoc by default. If MACOS_SIGN_IDENTITY is set (a Developer ID Application
# identity already present in the keychain), the app is signed with it using the hardened
# runtime and a secure timestamp, which is what notarization requires. Importing the
# certificate is the caller's job (see .github/workflows/release.yml).
#
# The app bundles the engine *ingredients*, not the engine: the uv binary, the pinned
# requirements exported from uv.lock, and the liteecho wheel. First-run setup builds the
# engine from these into ~/Library/Application Support/LiteEcho/engine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
APP_VERSION="${LITEECHO_VERSION:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIG=debug ;;
        --version) APP_VERSION="${2:?--version needs a value}"; shift ;;
        --version=*) APP_VERSION="${1#--version=}" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

BUILD="$ROOT/build"
APP="$BUILD/LiteEcho.app"
CONTENTS="$APP/Contents"
ENGINE="$CONTENTS/Resources/engine"
VERSION="${APP_VERSION#v}"
[[ -n "$VERSION" ]] || VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml" | head -1)"
[[ -n "$VERSION" ]] || { echo "could not determine version" >&2; exit 1; }
echo "==> Version $VERSION"

echo "==> Swift build ($CONFIG)"
swift build --package-path "$ROOT/app" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT/app" -c "$CONFIG" --show-bin-path)"

echo "==> Engine wheel and pinned requirements"
rm -rf "$BUILD/dist"
uv build --project "$ROOT" --wheel --out-dir "$BUILD/dist" >/dev/null
WHEEL="$(cd "$BUILD/dist" && ls liteecho-*.whl | head -1)"
uv export --project "$ROOT" --frozen --no-dev --no-emit-project --format requirements-txt \
    -o "$BUILD/requirements.txt" >/dev/null

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$ENGINE"
cp "$BIN_DIR/LiteEcho" "$CONTENTS/MacOS/LiteEcho"
# SwiftPM resource bundles, if any; Bundle.module finds them in Resources.
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] && cp -R "$bundle" "$CONTENTS/Resources/"
done
cp "$(readlink -f "$(command -v uv)")" "$ENGINE/uv"
cp "$BUILD/requirements.txt" "$ENGINE/requirements.txt"
cp "$BUILD/dist/$WHEEL" "$ENGINE/$WHEEL"
echo "$WHEEL" > "$ENGINE/wheel.txt"
echo "3.12" > "$ENGINE/python-version.txt"
if [[ -f "$ROOT/app/Assets/AppIcon.icns" ]]; then
    cp "$ROOT/app/Assets/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiteEcho</string>
    <key>CFBundleDisplayName</key><string>LiteEcho</string>
    <key>CFBundleIdentifier</key><string>dev.liteecho.app</string>
    <key>CFBundleExecutable</key><string>LiteEcho</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Audio or video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.audio</string><string>public.movie</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
    echo "==> Developer ID signing ($MACOS_SIGN_IDENTITY, hardened runtime)"
    # Inside-out: the bundled uv first, then the app. No entitlements are needed: the app
    # only spawns child processes (uv, Python), which are not bound by the app's runtime.
    SIGN=(codesign --force --sign "$MACOS_SIGN_IDENTITY" --options runtime --timestamp)
    "${SIGN[@]}" "$ENGINE/uv"
    "${SIGN[@]}" "$APP"
else
    echo "==> Ad-hoc signing"
    codesign --force --sign - "$ENGINE/uv"
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "Built $APP $VERSION ($(du -sh "$APP" | cut -f1))"
