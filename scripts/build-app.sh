#!/usr/bin/env bash
# Build Slotkeeper.app: a real application bundle, not a bare executable.
#
#   scripts/build-app.sh              build and install to ~/Applications/Slotkeeper.app
#   scripts/build-app.sh --dest DIR   install somewhere else
#   scripts/build-app.sh --open       reveal it in Finder afterwards
#
# The LaunchAgent runs the executable inside the bundle, so the menu-bar item, the Dock
# icon and login start are all the same app. Unsigned: macOS may ask the first time.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO/Slotkeeper"
DEST="$HOME/Applications"
OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift ;;
    --open) OPEN=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done
log() { printf '[build-app %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

command -v swift >/dev/null || { echo "swift not found; install Xcode or the Command Line Tools" >&2; exit 1; }
log "building release"
(cd "$PKG" && swift build -c release 2>&1 | tail -1)
BIN="$(cd "$PKG" && swift build -c release --show-bin-path)/Slotkeeper"
[[ -x "$BIN" ]] || { echo "build did not produce $BIN" >&2; exit 1; }

APP="$DEST/Slotkeeper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Slotkeeper"

VERSION="$(cd "$REPO" && git describe --tags --always 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Slotkeeper</string>
  <key>CFBundleDisplayName</key><string>Slotkeeper</string>
  <key>CFBundleIdentifier</key><string>work.penz.slotkeeper</string>
  <key>CFBundleExecutable</key><string>Slotkeeper</string>
  <key>CFBundleIconFile</key><string>Slotkeeper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST

# The icon: a gauge drawn from the same SF Symbol the menu bar uses, so the Dock,
# Spotlight and Cmd-Tab all show something recognisable rather than a blank page.
ICONSET="$(mktemp -d)/Slotkeeper.iconset"
mkdir -p "$ICONSET"
cat > "$ICONSET/render.swift" <<'SWIFT'
import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = CommandLine.arguments[1]
for size in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = CGFloat(size) * 0.22
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(size) * 0.04, dy: CGFloat(size) * 0.04),
                            xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.20, alpha: 1).setFill()
    path.fill()
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.54, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor(calibratedRed: 0.44, green: 0.78, blue: 0.96, alpha: 1).set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        let w = CGFloat(size) * 0.6, h = w * symbol.size.height / symbol.size.width
        tinted.draw(in: NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let scale = size <= 512 ? "" : ""
    _ = scale
    try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    if size >= 32 {
        try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}
SWIFT
if swift "$ICONSET/render.swift" "$ICONSET" 2>/dev/null; then
  rm -f "$ICONSET/render.swift"
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Slotkeeper.icns" 2>/dev/null; then
    log "icon built"
  else
    log "iconutil declined the iconset; the app keeps the generic icon"
  fi
else
  log "could not render the icon; the app keeps the generic icon"
fi

touch "$APP"
log "installed $APP"
echo "$APP/Contents/MacOS/Slotkeeper"
(( OPEN )) && open -R "$APP"
exit 0
