import AppKit

/// Export the supplied artwork at the canonical macOS icon sizes. No artwork is added.
struct IconExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func exportIcon() throws {
    guard CommandLine.arguments.count == 3 else {
        throw IconExportError(message: "Usage: draw_icon.swift <RumiIcon.png> <output.iconset>")
    }
    let masterURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard FileManager.default.isReadableFile(atPath: masterURL.path) else {
        throw IconExportError(message: "Rumi icon master is missing or unreadable: \(masterURL.path)")
    }
    let data = try Data(contentsOf: masterURL)
    let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    guard data.starts(with: pngSignature),
          let representation = NSBitmapImageRep(data: data),
          let source = representation.cgImage else {
        throw IconExportError(message: "Rumi icon master must be a valid PNG image: \(masterURL.path)")
    }
    guard source.width == source.height else {
        throw IconExportError(message: "Rumi icon master must be square; received \(source.width)×\(source.height).")
    }
    guard source.width >= 1024 else {
        throw IconExportError(message: "Rumi icon master must be at least 1024×1024 pixels; received \(source.width)×\(source.height).")
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw IconExportError(message: "Unable to create the icon export color space.")
    }

    func png(at pixels: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IconExportError(message: "Unable to allocate the \(pixels)×\(pixels) icon bitmap.")
        }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        guard let resized = context.makeImage(),
              let output = NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:]) else {
            throw IconExportError(message: "Unable to encode the \(pixels)×\(pixels) icon as PNG.")
        }
        return output
    }

    // Validate the master completely before touching the destination.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        try png(at: size).write(to: directory.appendingPathComponent("icon_\(size)x\(size).png"), options: .atomic)
        try png(at: size * 2).write(to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"), options: .atomic)
    }
    print("Exported 10 Rumi icon images from \(source.width)×\(source.height) PNG to \(directory.path)")
}

do {
    try exportIcon()
} catch {
    FileHandle.standardError.write(Data("Rumi icon export failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
