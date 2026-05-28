#!/bin/bash
# Regenerates the System Load app icon from a single drawn master:
#   - SystemLoad/Assets.xcassets/AppIcon.appiconset (bundled app icon)
#   - SystemLoad/Resources/AppIcon.icns (for create-dmg --volicon)
# Re-run after editing the drawing below.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MASTER="$WORK/master.png"
SWIFT="$WORK/draw.swift"

APPICONSET="$DIR/SystemLoad/Assets.xcassets/AppIcon.appiconset"
RES_DIR="$DIR/SystemLoad/Resources"

cat > "$SWIFT" <<'SWIFT'
import AppKit
let size = 1024.0
// Draw into a fixed 1024×1024 pixel buffer (1pt == 1px) so the output is exactly
// 1024 regardless of the display's backing scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
let margin = 100.0
let rect = NSRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
let radius = (size - 2*margin) * 0.2237
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// drop shadow under the squircle
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.shadowBlurRadius = 40
shadow.set()
NSColor.black.setFill()
bg.fill()
NSGraphicsContext.restoreGraphicsState()

// graphite gradient inside the squircle, with ascending load bars
NSGraphicsContext.saveGraphicsState()
bg.setClip()
let grad = NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1),
                      ending:   NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1))!
grad.draw(in: rect, angle: -90)

let area = rect.insetBy(dx: 165, dy: 175)
let gap = 40.0
let barW = (area.width - gap * 2) / 3
let heights = [0.42, 0.68, 0.96]
let colors: [NSColor] = [.systemGreen, .systemOrange, .systemRed]
for i in 0..<3 {
    let h = area.height * heights[i]
    let x = area.minX + Double(i) * (barW + gap)
    let r = NSRect(x: x, y: area.minY, width: barW, height: h)
    let p = NSBezierPath(roundedRect: r, xRadius: barW * 0.28, yRadius: barW * 0.28)
    colors[i].setFill()
    p.fill()
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

echo "→ Drawing master…"
swift "$SWIFT" "$MASTER"

echo "→ Building .iconset / .icns…"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" "$RES_DIR"
gen() { sips -z "$1" "$1" "$MASTER" --out "$2" >/dev/null; }   # sips -z height width
gen 16   "$ICONSET/icon_16x16.png"
gen 32   "$ICONSET/icon_16x16@2x.png"
gen 32   "$ICONSET/icon_32x32.png"
gen 64   "$ICONSET/icon_32x32@2x.png"
gen 128  "$ICONSET/icon_128x128.png"
gen 256  "$ICONSET/icon_128x128@2x.png"
gen 256  "$ICONSET/icon_256x256.png"
gen 512  "$ICONSET/icon_256x256@2x.png"
gen 512  "$ICONSET/icon_512x512.png"
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"

echo "→ Building Assets.xcassets/AppIcon.appiconset…"
mkdir -p "$APPICONSET"
gen 16   "$APPICONSET/icon_16.png"
gen 32   "$APPICONSET/icon_32.png"
gen 64   "$APPICONSET/icon_64.png"
gen 128  "$APPICONSET/icon_128.png"
gen 256  "$APPICONSET/icon_256.png"
gen 512  "$APPICONSET/icon_512.png"
cp "$MASTER" "$APPICONSET/icon_1024.png"

cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",   "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16",   "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

echo "✓ Icon generated:"
echo "   $APPICONSET"
echo "   $RES_DIR/AppIcon.icns"
