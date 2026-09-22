#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGBA {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func component(_ value: String) -> Double {
    if value.hasPrefix("0x"), let parsed = Int(value.dropFirst(2), radix: 16) {
        return Double(parsed) / 255.0
    }
    guard let parsed = Double(value) else { fail("invalid color component \(value)") }
    return parsed
}

func rgba(from color: [String: Any]) -> RGBA {
    guard let components = color["components"] as? [String: String],
          let red = components["red"],
          let green = components["green"],
          let blue = components["blue"],
          let alpha = components["alpha"] else {
        fail("unsupported colorset")
    }
    return RGBA(red: component(red), green: component(green), blue: component(blue), alpha: component(alpha))
}

func render(pdf source: URL, to destination: URL, scale: Int) {
    guard let provider = CGDataProvider(url: source as CFURL),
          let document = CGPDFDocument(provider),
          let page = document.page(at: 1) else {
        fail("cannot read PDF \(source.path)")
    }

    let bounds = page.getBoxRect(.mediaBox)
    let width = max(1, Int(ceil(bounds.width * CGFloat(scale))))
    let height = max(1, Int(ceil(bounds.height * CGFloat(scale))))
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        fail("cannot create bitmap for \(source.path)")
    }

    context.interpolationQuality = .high
    let destinationRect = CGRect(x: 0, y: 0, width: width, height: height)
    context.concatenate(page.getDrawingTransform(.mediaBox, rect: destinationRect, rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    guard let image = context.makeImage(),
          let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("cannot create PNG \(destination.path)")
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { fail("cannot write PNG \(destination.path)") }
}

func swiftNumber(_ value: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
}

guard CommandLine.arguments.count == 5 else {
    fail("usage: generate_portable_resources.swift <Media.xcassets> <PortableResources> <GeneratedColors.swift> <ColorEnumName>")
}

let fileManager = FileManager.default
let catalogDisplayPath = CommandLine.arguments[1]
let catalog = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
let colorsOutput = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
let colorEnumName = CommandLine.arguments[4]

guard catalog.lastPathComponent.hasSuffix(".xcassets"), output.lastPathComponent == "PortableResources" else {
    fail("refusing unexpected source/output paths")
}

try? fileManager.removeItem(at: output)
try! fileManager.createDirectory(at: output, withIntermediateDirectories: true)

let enumerator = fileManager.enumerator(at: catalog, includingPropertiesForKeys: nil)!
var generatedImages: [String] = []
var colors: [(String, RGBA, RGBA)] = []

for case let contentsURL as URL in enumerator where contentsURL.lastPathComponent == "Contents.json" {
    let parent = contentsURL.deletingLastPathComponent()
    let data = try! Data(contentsOf: contentsURL)
    guard let json = try! JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

    if parent.pathExtension == "imageset", let images = json["images"] as? [[String: Any]] {
        let logicalName = parent.deletingPathExtension().lastPathComponent
        for image in images {
            guard let filename = image["filename"] as? String else { continue }
            let source = parent.appendingPathComponent(filename)
            switch source.pathExtension.lowercased() {
            case "pdf":
                for scale in 1...3 {
                    let suffix = scale == 1 ? "" : "@\(scale)x"
                    render(pdf: source, to: output.appendingPathComponent("\(logicalName)\(suffix).png"), scale: scale)
                }
                let relativeSource = source.path.components(separatedBy: "/\(catalog.lastPathComponent)/").last ?? filename
                generatedImages.append("\(logicalName) <- \(relativeSource)")
            case "png":
                try! fileManager.copyItem(at: source, to: output.appendingPathComponent("\(logicalName).png"))
                let relativeSource = source.path.components(separatedBy: "/\(catalog.lastPathComponent)/").last ?? filename
                generatedImages.append("\(logicalName) <- \(relativeSource)")
            default:
                continue
            }
            break
        }
    }

    if parent.pathExtension == "colorset", let entries = json["colors"] as? [[String: Any]] {
        var light: RGBA?
        var dark: RGBA?
        for entry in entries {
            guard let color = entry["color"] as? [String: Any] else { continue }
            let parsed = rgba(from: color)
            let appearances = entry["appearances"] as? [[String: String]]
            let isDark = appearances?.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" } == true
            if isDark { dark = parsed } else { light = parsed }
        }
        if let light {
            colors.append((parent.deletingPathExtension().lastPathComponent, light, dark ?? light))
        }
    }
}

let colorDeclarations = colors.sorted { $0.0 < $1.0 }.map { name, light, dark in
    "    public static let \(name) = dynamic(light: (\(swiftNumber(light.red)), \(swiftNumber(light.green)), \(swiftNumber(light.blue)), \(swiftNumber(light.alpha))), dark: (\(swiftNumber(dark.red)), \(swiftNumber(dark.green)), \(swiftNumber(dark.blue)), \(swiftNumber(dark.alpha))))"
}.joined(separator: "\n")

let generatedSwift = """
// Generated by Tools/generate_portable_resources.swift. Do not edit by hand.
import SwiftUI
import UIKit

public enum \(colorEnumName) {
    private typealias Components = (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)

    private static func dynamic(light: Components, dark: Components) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        })
    }

\(colorDeclarations)
}
"""
try! fileManager.createDirectory(at: colorsOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
try! Data(generatedSwift.utf8).write(to: colorsOutput)

let sourceNote = """
# Portable resource provenance

Generated by `Tools/generate_portable_resources.swift` from the retained MIT-licensed
asset catalog at `\(catalogDisplayPath)`.

PDF vectors are rasterized with CoreGraphics at 1x, 2x and 3x. Existing PNG files
are copied byte-for-byte. The original catalog remains the visual source of truth
and is excluded only from SwiftPM compilation to avoid an `actool` dependency.

\(generatedImages.sorted().map { "- \($0)" }.joined(separator: "\n"))
"""
try! Data(sourceNote.utf8).write(to: output.appendingPathComponent("SOURCE.md"))
