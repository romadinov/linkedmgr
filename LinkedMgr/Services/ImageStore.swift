import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps post images as files in Application Support, normalised for LinkedIn
/// (JPEG/PNG/GIF only, under ~36 MP), so HEIC photos from iPhone just work.
enum ImageStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LinkedMgr/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Longest edge we upload. LinkedIn displays far smaller; this keeps uploads quick.
    static let maxPixelSize = 4096

    enum ImageError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That file isn't an image LinkedMgr can read." }
    }

    /// Saves image data and returns the stored file name.
    static func save(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { throw ImageError.unreadable }

        // Animated GIFs are kept as they are; LinkedIn accepts up to 250 frames.
        if UTType(type) == .gif, CGImageSourceGetCount(source) > 1 {
            let name = UUID().uuidString + ".gif"
            try data.write(to: directory.appendingPathComponent(name))
            return name
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageError.unreadable
        }

        let keepPNG = UTType(type) == .png
        let name = UUID().uuidString + (keepPNG ? ".png" : ".jpg")
        let url = directory.appendingPathComponent(name)
        let outType = (keepPNG ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, outType, 1, nil) else {
            throw ImageError.unreadable
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageError.unreadable }
        return name
    }

    static func save(contentsOf url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try save(Data(contentsOf: url))
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
