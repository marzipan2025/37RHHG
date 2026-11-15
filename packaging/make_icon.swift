// 정사각 그림을 macOS 아이콘 틀(1024 캔버스 안 824 둥근 사각, 반지름 185)에 맞춰 자른다.
// 쓰기: swift packaging/make_icon.swift 원본.png app/icon.png
import AppKit
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!
let size = 1024, inset: CGFloat = 100, r: CGFloat = 185
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
let box = NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
NSBezierPath(roundedRect: box, xRadius: r, yRadius: r).addClip()
src.draw(in: box, from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
