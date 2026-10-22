#!/usr/bin/env swift
// Renders the placeholder Dev Mail app icon into every size listed in
// DevMail/Assets.xcassets/AppIcon.appiconset/Contents.json and rewrites that
// file with the generated filenames.
//
// Usage (from the repo root): swift scripts/generate-app-icon.swift
//
// The artwork is drawn as vectors on a 1024-point canvas following the macOS
// icon grid (824-point rounded rect inset 100 points, room for a drop shadow)
// and scaled to each pixel size, so every PNG is crisp.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconSetPath = "DevMail/Assets.xcassets/AppIcon.appiconset"
let contentsPath = "\(iconSetPath)/Contents.json"
let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let envelope = CGRect(x: 232, y: 292, width: 560, height: 400)

struct IconImage {
    let idiom: String
    let scale: String
    let size: String

    var points: Int {
        guard let width = size.split(separator: "x").first, let value = Int(width) else {
            fail("Unsupported size \"\(size)\" in \(contentsPath)")
        }
        return value
    }

    var multiplier: Int {
        guard let value = Int(scale.replacingOccurrences(of: "x", with: "")) else {
            fail("Unsupported scale \"\(scale)\" in \(contentsPath)")
        }
        return value
    }

    var pixels: Int { points * multiplier }

    var filename: String {
        multiplier == 1 ? "icon_\(size).png" : "icon_\(size)@\(scale).png"
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let srgb: CGColorSpace = {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        fail("sRGB color space is unavailable")
    }
    return space
}()

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Background squircle with a soft drop shadow and a vertical gradient.
func drawBackground(in context: CGContext) {
    let tilePath = roundedRect(tile, radius: 185)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(32, 36, 48))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    guard
        let background = CGGradient(
            colorsSpace: srgb,
            colors: [color(64, 72, 92), color(22, 25, 34)] as CFArray,
            locations: [0, 1]
        )
    else {
        fail("Could not create background gradient")
    }
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 512, y: tile.maxY),
        end: CGPoint(x: 512, y: tile.minY),
        options: []
    )
    context.restoreGState()
}

/// White envelope with a teal flap and side folds.
func drawEnvelope(in context: CGContext) {
    let envelopePath = roundedRect(envelope, radius: 48)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
    context.addPath(envelopePath)
    context.setFillColor(color(255, 255, 255))
    context.fillPath()
    context.restoreGState()

    // Envelope flap and side folds, clipped to the body.
    context.saveGState()
    context.addPath(envelopePath)
    context.clip()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(28)
    context.setStrokeColor(color(13, 148, 136))

    let flapTip = CGPoint(x: envelope.midX, y: envelope.minY + 150)
    context.move(to: CGPoint(x: envelope.minX + 20, y: envelope.maxY - 20))
    context.addLine(to: flapTip)
    context.addLine(to: CGPoint(x: envelope.maxX - 20, y: envelope.maxY - 20))
    context.strokePath()

    context.setStrokeColor(color(13, 148, 136, 0.4))
    context.setLineWidth(20)
    context.move(to: CGPoint(x: envelope.minX + 24, y: envelope.minY + 24))
    context.addLine(to: CGPoint(x: envelope.midX - 120, y: envelope.minY + 190))
    context.move(to: CGPoint(x: envelope.maxX - 24, y: envelope.minY + 24))
    context.addLine(to: CGPoint(x: envelope.midX + 120, y: envelope.minY + 190))
    context.strokePath()
    context.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) {
    guard
        let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: srgb,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else {
        fail("Could not create a \(pixels)x\(pixels) bitmap context")
    }

    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    drawBackground(in: context)
    drawEnvelope(in: context)

    guard
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        fail("Could not create PNG for \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("Could not write \(url.path)")
    }
}

func loadImages() -> [IconImage] {
    guard
        let data = FileManager.default.contents(atPath: contentsPath),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let images = json["images"] as? [[String: Any]]
    else {
        fail("Could not read \(contentsPath); run this script from the repo root")
    }

    return images.map { entry in
        guard
            let idiom = entry["idiom"] as? String,
            let scale = entry["scale"] as? String,
            let size = entry["size"] as? String
        else {
            fail("Malformed image entry in \(contentsPath): \(entry)")
        }
        return IconImage(idiom: idiom, scale: scale, size: size)
    }
}

/// Writes Contents.json in the same compact, one-entry-per-line style Xcode uses.
func writeContents(_ images: [IconImage]) {
    let entries = images.map { image in
        "    { \"filename\" : \"\(image.filename)\", \"idiom\" : \"\(image.idiom)\", "
            + "\"scale\" : \"\(image.scale)\", \"size\" : \"\(image.size)\" }"
    }
    let json = """
        {
          "images" : [
        \(entries.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
    do {
        try json.write(toFile: contentsPath, atomically: true, encoding: .utf8)
    } catch {
        fail("Could not write \(contentsPath): \(error.localizedDescription)")
    }
}

let images = loadImages()
for image in images {
    let url = URL(fileURLWithPath: "\(iconSetPath)/\(image.filename)")
    renderPNG(pixels: image.pixels, to: url)
    print("wrote \(url.path) (\(image.pixels)x\(image.pixels))")
}
writeContents(images)
print("updated \(contentsPath)")
