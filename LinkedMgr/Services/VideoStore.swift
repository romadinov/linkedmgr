import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Keeps post videos as MP4 files in Application Support, checked against LinkedIn's
/// limits (MP4, 3 s – 30 min, up to 500 MB). iPhone .mov/HEVC clips are converted to H.264 MP4.
enum VideoStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LinkedMgr/Videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let minDuration: Double = 3
    static let maxDuration: Double = 30 * 60
    static let maxBytes: Int64 = 500 * 1024 * 1024

    enum VideoError: LocalizedError {
        case unreadable, tooShort, tooLong, tooBig(Int64)

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn't a video LinkedMgr can read."
            case .tooShort: "LinkedIn needs videos of at least 3 seconds."
            case .tooLong: "LinkedIn accepts videos up to 30 minutes."
            case .tooBig(let bytes):
                "The video is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); LinkedIn accepts up to 500 MB. Trim or export it smaller."
            }
        }
    }

    /// Copies (MP4) or converts (anything else) the video and returns the stored file name.
    static func save(contentsOf source: URL) async throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite else {
            throw VideoError.unreadable
        }
        guard duration >= minDuration else { throw VideoError.tooShort }
        guard duration <= maxDuration else { throw VideoError.tooLong }

        let name = UUID().uuidString + ".mp4"
        let dest = directory.appendingPathComponent(name)
        if UTType(filenameExtension: source.pathExtension)?.conforms(to: .mpeg4Movie) == true {
            try FileManager.default.copyItem(at: source, to: dest)
        } else {
            // 1080p H.264 plays everywhere LinkedIn does; HEVC from iPhones may not.
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
                throw VideoError.unreadable
            }
            do {
                try await session.export(to: dest, as: .mp4)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
        }

        let bytes = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard bytes <= maxBytes else {
            try? FileManager.default.removeItem(at: dest)
            throw VideoError.tooBig(bytes)
        }
        return name
    }

    static func copy(_ fileName: String) throws -> String {
        let name = UUID().uuidString + ".mp4"
        try FileManager.default.copyItem(at: directory.appendingPathComponent(fileName),
                                         to: directory.appendingPathComponent(name))
        return name
    }

    static func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    static func thumbnail(_ fileName: String, maxSize: CGFloat) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: directory.appendingPathComponent(fileName)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize * 2, height: maxSize * 2)
        guard let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    static func duration(_ fileName: String) async -> Double? {
        try? await AVURLAsset(url: directory.appendingPathComponent(fileName)).load(.duration).seconds
    }
}
