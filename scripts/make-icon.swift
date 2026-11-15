// Renders AnyRemote's app icon: a window mirrored from another Mac (the
// faint one behind) with a pointer on the copy. Usage:
//   swift scripts/make-icon.swift <out.png> [release|dev]
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args[1])
let isDev = args.count > 2 && args[2] == "dev"
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Body: the macOS icon grid, 824 pt square with a soft shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rounded(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x000000)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let colors = isDev ? [color(0xFFB13B), color(0xF0592A)] : [color(0x4FA8FF), color(0x2B3FD6)]
let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// A faint glow at the top, for depth.
let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
ctx.restoreGState()

// The host's window: faint, up and to the left.
let back = CGRect(x: 214, y: 404, width: 450, height: 340)
ctx.addPath(rounded(back, 40)); ctx.setFillColor(color(0xFFFFFF, 0.20)); ctx.fillPath()
ctx.addPath(rounded(back.insetBy(dx: 3, dy: 3), 37)); ctx.setStrokeColor(color(0xFFFFFF, 0.55))
ctx.setLineWidth(6); ctx.setLineDash(phase: 0, lengths: [22, 16]); ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// The mirror: solid, down and to the right.
let front = CGRect(x: 350, y: 250, width: 470, height: 360)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x0A1240, 0.45))
ctx.addPath(rounded(front, 40)); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(front, 40)); ctx.clip()
ctx.setFillColor(color(0xE9ECF3)); ctx.fill(CGRect(x: front.minX, y: front.maxY - 72, width: front.width, height: 72))
ctx.restoreGState()
for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    ctx.setFillColor(color(UInt32(hex)))
    ctx.fillEllipse(in: CGRect(x: front.minX + 32 + CGFloat(index) * 42, y: front.maxY - 50, width: 28, height: 28))
}
// Content lines.
ctx.setFillColor(color(0xD5DAE6))
for (index, width) in [300.0, 230, 270].enumerated() {
    ctx.addPath(rounded(CGRect(x: front.minX + 40, y: front.maxY - 130 - CGFloat(index) * 52, width: width, height: 22), 11))
    ctx.fillPath()
}

// The pointer: the other Mac in control.
let tip = CGPoint(x: 630, y: 430)
let pointer = CGMutablePath()
let points: [CGPoint] = [(0, 0), (0, -190), (44, -148), (76, -222), (110, -207), (79, -134), (138, -134)]
    .map { CGPoint(x: tip.x + $0.0 * 0.78, y: tip.y + $0.1 * 0.78) }
pointer.addLines(between: points); pointer.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.35))
ctx.addPath(pointer); ctx.setFillColor(color(0x111318)); ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(14); ctx.setLineJoin(.round); ctx.drawPath(using: .fillStroke)
ctx.restoreGState()
ctx.addPath(pointer); ctx.setFillColor(color(0x111318)); ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: output)
