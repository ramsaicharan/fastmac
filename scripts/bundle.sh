#!/bin/bash
# Build a dependency-free native executable and wrap it as a menu-bar .app.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
APP="build/FastMac.app"
VERSION="${FASTMAC_VERSION:-2.1.0}"
BUILD_NUMBER="${FASTMAC_BUILD:-10}"
CONF="${1:-release}"
case "$CONF" in debug|release) ;; *) echo "usage: scripts/bundle.sh [debug|release]"; exit 2 ;; esac
SIGNING_IDENTITY="${FASTMAC_SIGNING_IDENTITY--}"
if [ "$SIGNING_IDENTITY" != "-" ]; then
  # Resolve an exact valid certificate name or SHA-1 to one identity before
  # building. A requested signer must never silently become an ad-hoc build.
  if ! SIGNER_HASH="$(/usr/bin/security find-identity -v -p codesigning |
    FASTMAC_REQUESTED_SIGNER="$SIGNING_IDENTITY" /usr/bin/awk '
      BEGIN { requested = ENVIRON["FASTMAC_REQUESTED_SIGNER"] }
      length($2) == 40 && $2 ~ /^[[:xdigit:]]+$/ {
        hash = $2
        name = $0
        sub(/^[^"]*"/, "", name)
        sub(/"[[:space:]]*$/, "", name)
        if (tolower(requested) == tolower(hash) || requested == name) {
          matches++
          selected = hash
        }
      }
      END { if (matches == 1) print selected; else exit 1 }
    ')"; then
    echo "Requested FASTMAC_SIGNING_IDENTITY is unavailable or ambiguous." >&2
    echo "Use an exact valid code-signing certificate name or SHA-1 from security find-identity -v -p codesigning." >&2
    echo "No build or replacement was performed. Omit the variable only for an intentional ad-hoc local build." >&2
    exit 1
  fi
  SIGNING_IDENTITY="$SIGNER_HASH"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"

# Command Line Tools can still build if Xcode's licence has not been accepted.
if ! swift build --disable-sandbox --cache-path "$PWD/.build/package-cache" -c "$CONF" -j 4; then
  echo "  Trying the Command Line Tools toolchain"
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  swift build --disable-sandbox --cache-path "$PWD/.build/package-cache" -c "$CONF" -j 4
fi
BIN_DIR="$(swift build --disable-sandbox --show-bin-path -c "$CONF")"
BIN="$BIN_DIR/FastMac"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }
# Keep the documented shortcut current when switching SwiftPM toolchains/backends.
if [ -L ".build/$CONF" ] || [ ! -e ".build/$CONF" ]; then
  ln -sfn "$BIN_DIR" ".build/$CONF"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fastmac-bundle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BUNDLE="$WORK/$APP"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" "$WORK/AppIcon.iconset"
cp "$BIN" "$BUNDLE/Contents/MacOS/FastMac"

# Draw the icon with AppKit, so packaging needs no asset downloader or image library.
cat > "$WORK/AppIcon.swift" <<'SWIFT'
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func drawIcon(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let plate = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                             xRadius: 184, yRadius: 184)
    let gradient = NSGradient(starting: NSColor(red: 0.08, green: 0.16, blue: 0.32, alpha: 1),
                              ending: NSColor(red: 0.14, green: 0.34, blue: 0.70, alpha: 1))!
    gradient.draw(in: plate, angle: 40)

    func tile(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 28) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    tile(NSRect(x: 244, y: 405, width: 280, height: 370),
         NSColor(red: 0.65, green: 0.94, blue: 0.88, alpha: 1))
    tile(NSRect(x: 548, y: 597, width: 232, height: 178),
         NSColor(red: 0.83, green: 0.89, blue: 1, alpha: 1))
    tile(NSRect(x: 548, y: 405, width: 232, height: 168),
         NSColor(red: 0.41, green: 0.71, blue: 1, alpha: 1))
    tile(NSRect(x: 244, y: 253, width: 536, height: 112), .white, radius: 34)
    NSColor(red: 0.10, green: 0.24, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 684, y: 293, width: 32, height: 32)).fill()
    NSBezierPath(ovalIn: NSRect(x: 628, y: 293, width: 32, height: 32)).fill()
    return bitmap.representation(using: .png, properties: [:])!
}
for points in [16, 32, 128, 256, 512] {
    try drawIcon(points).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(points * 2).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
SWIFT
swift "$WORK/AppIcon.swift" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FastMac</string>
  <key>CFBundleDisplayName</key><string>FastMac</string>
  <key>CFBundleExecutable</key><string>FastMac</string>
  <key>CFBundleIdentifier</key><string>app.fastmac.FastMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.6.0</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>FastMac · MIT License</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>FastMac measures what is using space on your Desktop when you request a scan.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>FastMac measures what is using space in your Documents when you request a scan.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>FastMac measures what is using space in your Downloads when you request a scan.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>FastMac can map external drives you choose to scan.</string>
</dict>
</plist>
PLIST
# Release builds set FASTMAC_VERSION from the git tag.
plutil -replace CFBundleShortVersionString -string "$VERSION" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"

# Default local builds are ad-hoc. Set FASTMAC_SIGNING_IDENTITY to keep using an
# existing certificate identity across builds. Notarization is a separate step.
# The hardened runtime is required for notarization, so every build uses it; testing
# ad-hoc builds this way catches anything it would block. A real certificate also
# needs Apple's secure timestamp.
SIGN_FLAGS=(--force --options runtime --identifier app.fastmac.FastMac)
if [ "$SIGNING_IDENTITY" != "-" ]; then SIGN_FLAGS+=(--timestamp); fi
codesign "${SIGN_FLAGS[@]}" --sign "$SIGNING_IDENTITY" "$BUNDLE"
codesign --verify --deep --strict "$BUNDLE"
plutil -lint "$BUNDLE/Contents/Info.plist"
# Replace only the generated app after a successful build and signature check.
rm -rf "$APP"
mv "$BUNDLE" "$APP"
echo "built $APP"
codesign -dv "$APP" 2>&1 | awk '/Signature|Identifier|Authority|TeamIdentifier/ { print "  " $0 }'
du -sh "$APP" | sed 's/^/  /'
