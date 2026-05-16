#!/usr/bin/env swift
//
// Generates the Picky DMG installer background image.
//
// Usage:
//   swift scripts/dmg/generate-background.swift
//
// Outputs (next to this script):
//   background.png       (660 x 400, @1x)
//   background@2x.png    (1320 x 800, @2x)
//   background.tiff      multi-representation TIFF (Finder picks the
//                         correct rep on Retina vs non-Retina)
//
// The image is drawn with CoreGraphics and CoreText so the script has no
// external dependencies. It is meant to be re-run whenever the design
// changes; the resulting files are committed to the repo and the CI/local
// DMG packagers just consume them.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Layout

let width: CGFloat = 660
let height: CGFloat = 400

// Icon centers must match the AppleScript in create-styled-dmg.sh.
let leftIconCenter = CGPoint(x: 175, y: 220)
let rightIconCenter = CGPoint(x: 485, y: 220)
let iconBoxSize: CGFloat = 128

// MARK: - Colors (Picky brand: light surface + blue accent)

func color(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: a)
}

let bgTop = color(0xF6, 0xF9, 0xFD)
let bgBottom = color(0xE6, 0xEE, 0xF8)
let accent = color(0x5B, 0x8D, 0xEF)
let accentSoft = color(0x5B, 0x8D, 0xEF, 0.18)
let ink = color(0x14, 0x1B, 0x2D)
let inkSoft = color(0x14, 0x1B, 0x2D, 0.55)

// MARK: - Drawing

func renderBitmap(scale: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(width * scale)
    let pxH = Int(height * scale)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        FileHandle.standardError.write("Failed to create CGContext\n".data(using: .utf8)!)
        exit(1)
    }

    ctx.scaleBy(x: scale, y: scale)
    // Flip so that drawing uses top-left origin (matches our layout math).
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(true)
    ctx.setShouldSmoothFonts(true)
    ctx.setAllowsFontSubpixelPositioning(true)
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.setAllowsFontSubpixelQuantization(false)
    ctx.setShouldSubpixelQuantizeFonts(false)
    ctx.interpolationQuality = .high

    drawBackground(in: ctx)
    drawDecor(in: ctx)
    drawHeader(in: ctx)
    drawDropZones(in: ctx)
    drawArrow(in: ctx)
    drawFooter(in: ctx)

    guard let cgImage = ctx.makeImage() else {
        FileHandle.standardError.write("Failed to create CGImage\n".data(using: .utf8)!)
        exit(1)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    // Mark the pixel size so NSImage/Finder treats this as an @Nx rep.
    bitmap.size = NSSize(width: width, height: height)
    return bitmap
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("Failed to encode PNG\n".data(using: .utf8)!)
        exit(1)
    }
    try? data.write(to: url)
    print("Wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

func writeMultiRepTIFF(_ reps: [NSBitmapImageRep], to url: URL) {
    for rep in reps {
        rep.setCompression(.lzw, factor: 1.0)
    }
    guard
        let data = NSBitmapImageRep.representationOfImageReps(
            in: reps,
            using: .tiff,
            properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue]
        )
    else {
        FileHandle.standardError.write("Failed to encode TIFF\n".data(using: .utf8)!)
        exit(1)
    }
    try? data.write(to: url)
    let sizes = reps.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ", ")
    print("Wrote \(url.path) (reps: \(sizes), \(data.count / 1024) KB)")
}

func drawBackground(in ctx: CGContext) {
    // Soft vertical gradient.
    let colors = [bgTop, bgBottom] as CFArray
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.saveGState()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: height),
        options: []
    )
    ctx.restoreGState()
}

func drawDecor(in ctx: CGContext) {
    // Two soft radial blobs in Picky blue for a tasteful brand glow.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let glow = CGGradient(
        colorsSpace: space,
        colors: [color(0x5B, 0x8D, 0xEF, 0.22), color(0x5B, 0x8D, 0xEF, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: -40, y: -30),
        startRadius: 0,
        endCenter: CGPoint(x: -40, y: -30),
        endRadius: 260,
        options: []
    )
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: width + 60, y: height + 40),
        startRadius: 0,
        endCenter: CGPoint(x: width + 60, y: height + 40),
        endRadius: 280,
        options: []
    )
    ctx.restoreGState()
}

func drawText(
    _ text: String,
    in ctx: CGContext,
    at point: CGPoint,
    font: NSFont,
    color cgColor: CGColor,
    align: CTTextAlignment = .center,
    maxWidth: CGFloat = 600,
    tracking: CGFloat = 0
) {
    var alignment = align
    let paragraphSetting = CTParagraphStyleSetting(
        spec: .alignment,
        valueSize: MemoryLayout<CTTextAlignment>.size,
        value: &alignment
    )
    let paragraph = CTParagraphStyleCreate([paragraphSetting], 1)

    let nsColor = NSColor(cgColor: cgColor) ?? .black
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: nsColor,
        .paragraphStyle: paragraph,
        .kern: tracking,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)

    let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        CFRangeMake(0, attributed.length),
        nil,
        CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
        nil
    )
    let textRect: CGRect
    switch align {
    case .center:
        textRect = CGRect(
            x: point.x - maxWidth / 2,
            y: point.y,
            width: maxWidth,
            height: suggested.height
        )
    case .right:
        textRect = CGRect(
            x: point.x - maxWidth,
            y: point.y,
            width: maxWidth,
            height: suggested.height
        )
    default:
        textRect = CGRect(x: point.x, y: point.y, width: maxWidth, height: suggested.height)
    }

    let path = CGPath(rect: textRect, transform: nil)
    let frame = CTFramesetterCreateFrame(
        framesetter,
        CFRangeMake(0, attributed.length),
        path,
        nil
    )

    ctx.saveGState()
    // Flip locally so CoreText draws right-side up inside our flipped context.
    ctx.translateBy(x: 0, y: textRect.origin.y + textRect.size.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -textRect.origin.y)
    CTFrameDraw(frame, ctx)
    ctx.restoreGState()
}

func drawHeader(in ctx: CGContext) {
    let titleFont =
        NSFont(name: "SFProDisplay-Bold", size: 30)
        ?? NSFont.systemFont(ofSize: 30, weight: .bold)
    drawText(
        "Install Picky",
        in: ctx,
        at: CGPoint(x: width / 2, y: 48),
        font: titleFont,
        color: ink,
        tracking: -0.3
    )

    let subtitleFont =
        NSFont(name: "SFProText-Regular", size: 14)
        ?? NSFont.systemFont(ofSize: 14, weight: .regular)
    drawText(
        "Drag Picky into the Applications folder",
        in: ctx,
        at: CGPoint(x: width / 2, y: 92),
        font: subtitleFont,
        color: inkSoft
    )
}

func drawDropZones(in ctx: CGContext) {
    // Soft circular spotlight under each icon position to make the layout
    // legible even before Finder finishes positioning the icons.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let halo = CGGradient(
        colorsSpace: space,
        colors: [accentSoft, color(0x5B, 0x8D, 0xEF, 0)] as CFArray,
        locations: [0, 1]
    )!
    for center in [leftIconCenter, rightIconCenter] {
        ctx.drawRadialGradient(
            halo,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: iconBoxSize * 0.95,
            options: []
        )
    }
}

func drawArrow(in ctx: CGContext) {
    let y = leftIconCenter.y
    let startX = leftIconCenter.x + iconBoxSize / 2 + 18
    let endX = rightIconCenter.x - iconBoxSize / 2 - 18
    let shaftHeight: CGFloat = 10
    let headWidth: CGFloat = 30
    let headHeight: CGFloat = 38

    let path = CGMutablePath()
    let shaftLeft = startX
    let shaftRight = endX - headWidth + 6
    path.move(to: CGPoint(x: shaftLeft, y: y - shaftHeight / 2))
    path.addLine(to: CGPoint(x: shaftRight, y: y - shaftHeight / 2))
    path.addLine(to: CGPoint(x: shaftRight, y: y - headHeight / 2))
    path.addLine(to: CGPoint(x: endX, y: y))
    path.addLine(to: CGPoint(x: shaftRight, y: y + headHeight / 2))
    path.addLine(to: CGPoint(x: shaftRight, y: y + shaftHeight / 2))
    path.addLine(to: CGPoint(x: shaftLeft, y: y + shaftHeight / 2))
    path.closeSubpath()

    // Soft drop shadow for the arrow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: 4),
        blur: 12,
        color: color(0x5B, 0x8D, 0xEF, 0.35)
    )
    ctx.addPath(path)
    ctx.setFillColor(accent)
    ctx.fillPath()
    ctx.restoreGState()
}

func drawFooter(in ctx: CGContext) {
    let footerFont =
        NSFont(name: "SFProText-Regular", size: 11)
        ?? NSFont.systemFont(ofSize: 11, weight: .regular)
    drawText(
        "Local-first command center for Pi",
        in: ctx,
        at: CGPoint(x: width / 2, y: height - 36),
        font: footerFont,
        color: color(0x14, 0x1B, 0x2D, 0.4),
        tracking: 0.4
    )
}

// MARK: - Main

let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outDir = scriptPath
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let rep1x = renderBitmap(scale: 1)
let rep2x = renderBitmap(scale: 2)

writePNG(rep1x, to: outDir.appendingPathComponent("background.png"))
writePNG(rep2x, to: outDir.appendingPathComponent("background@2x.png"))
writeMultiRepTIFF([rep1x, rep2x], to: outDir.appendingPathComponent("background.tiff"))
