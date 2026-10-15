import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconBuildError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

let fileManager = FileManager.default
let iconSizes = [16, 32, 128, 256, 512]

func loadPNG(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw IconBuildError.invalid("Cannot decode a single-image PNG: \(url.path)")
    }
    return image
}

func verifyPNG(_ url: URL, pixels: Int) throws {
    let image = try loadPNG(url)
    guard image.width == pixels, image.height == pixels else {
        throw IconBuildError.invalid("Expected \(pixels)×\(pixels) pixels: \(url.path)")
    }
}

func writePNG(_ image: CGImage, pixels: Int, to url: URL) throws {
    // A pixel-backed context avoids NSImage.lockFocus's display-dependent scale.
    // Its transparent initial contents preserve the master's alpha channel.
    let colorSpace = image.colorSpace?.model == .rgb
        ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw IconBuildError.invalid("Cannot create the \(pixels)×\(pixels) bitmap context")
    }
    context.interpolationQuality = .high
    context.setRenderingIntent(.relativeColorimetric)
    context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let resized = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw IconBuildError.invalid("Cannot encode PNG: \(url.path)")
    }
    CGImageDestinationAddImage(destination, resized, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconBuildError.invalid("Cannot finish PNG: \(url.path)")
    }
    try verifyPNG(url, pixels: pixels)
}

func iconFileName(size: Int, scale: Int) -> String {
    "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
}

func runIconutil(_ arguments: [String]) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw IconBuildError.invalid("iconutil failed (\(process.terminationStatus)): \(detail)")
    }
}

func buildIcons(root: URL) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw IconBuildError.invalid("Repository directory does not exist: \(root.path)")
    }
    let assets = root.appendingPathComponent("Assets", isDirectory: true)
    let masterURL = assets.appendingPathComponent("AppIcon-master.png")
    let master = try loadPNG(masterURL)
    guard master.width == master.height, master.width >= 1024 else {
        throw IconBuildError.invalid("AppIcon-master.png must be square and at least 1024×1024 pixels (found \(master.width)×\(master.height))")
    }

    let staging = assets.appendingPathComponent(".appicon-build-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
    var removeStaging = true
    defer {
        if removeStaging { try? fileManager.removeItem(at: staging) }
    }

    let iconset = staging.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fileManager.createDirectory(at: iconset, withIntermediateDirectories: false)
    for size in iconSizes {
        for scale in [1, 2] {
            try writePNG(master, pixels: size * scale, to: iconset.appendingPathComponent(iconFileName(size: size, scale: scale)))
        }
    }
    try fileManager.copyItem(
        at: iconset.appendingPathComponent(iconFileName(size: 512, scale: 2)),
        to: staging.appendingPathComponent("AppIcon.png")
    )

    let icns = staging.appendingPathComponent("AppIcon.icns")
    try runIconutil(["--convert", "icns", "--output", icns.path, iconset.path])
    // Decode the finished container as well as checking the source PNG sizes.
    let roundTrip = staging.appendingPathComponent("Verified.iconset", isDirectory: true)
    try runIconutil(["--convert", "iconset", "--output", roundTrip.path, icns.path])
    for size in iconSizes {
        for scale in [1, 2] {
            try verifyPNG(roundTrip.appendingPathComponent(iconFileName(size: size, scale: scale)), pixels: size * scale)
        }
    }

    // Publish only after every representation and the ICNS container validate.
    // Keep previous assets available for rollback if a filesystem operation fails.
    let backup = staging.appendingPathComponent("Previous", isDirectory: true)
    try fileManager.createDirectory(at: backup, withIntermediateDirectories: false)
    var started: [(name: String, hadOriginal: Bool)] = []
    do {
        for name in ["AppIcon.iconset", "AppIcon.png", "AppIcon.icns"] {
            let target = assets.appendingPathComponent(name)
            let hadOriginal = fileManager.fileExists(atPath: target.path)
            if hadOriginal {
                try fileManager.moveItem(at: target, to: backup.appendingPathComponent(name))
            }
            started.append((name, hadOriginal))
            try fileManager.moveItem(at: staging.appendingPathComponent(name), to: target)
        }
    } catch {
        let publishError = error
        var rollbackErrors: [String] = []
        for item in started.reversed() {
            do {
                let target = assets.appendingPathComponent(item.name)
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                if item.hadOriginal { try fileManager.moveItem(at: backup.appendingPathComponent(item.name), to: target) }
            } catch {
                rollbackErrors.append("\(item.name): \(error.localizedDescription)")
            }
        }
        if !rollbackErrors.isEmpty {
            removeStaging = false
            throw IconBuildError.invalid("\(publishError.localizedDescription)\nRollback needs attention; previous assets are retained in \(backup.path): \(rollbackErrors.joined(separator: "; "))")
        }
        throw publishError
    }
    print("Generated AppIcon.png (1024×1024), 10 iconset PNGs, and validated AppIcon.icns from \(masterURL.path)")
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw IconBuildError.invalid("Usage: swift scripts/make-icon.swift /absolute/path/to/Wordglide")
    }
    try buildIcons(root: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL)
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
