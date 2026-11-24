import CoreGraphics
import Foundation
import ImageIO
import Observation
import OpenScreensCore
import UniformTypeIdentifiers

/// Last-seen pictures of saved computers, shown on their library cards.
///
/// Previews are small JPEGs kept in the app's own storage. They exist purely
/// for recognition, are never synced, and can be turned off entirely.
@Observable
public final class PreviewStore {
    /// The store the app keeps on disk. ``AppModel/previews`` is the one to
    /// use: a model that keeps nothing on disk has a store of its own.
    public static let shared = PreviewStore()

    /// Bumped whenever a preview changes so views showing one reload it.
    public private(set) var revision = 0

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var cache: [UUID: CGImage] = [:]

    /// Longest edge of a stored preview, in pixels.
    public static let maximumDimension = 960

    /// - Parameter directory: Where the previews are kept. With none they
    ///   are kept in memory and gone with the store, which is what a model
    ///   that touches no disk wants: a test, or a preview in Xcode.
    public init(directory: URL? = StorageLocation.previewsDirectory) {
        self.directory = directory
    }

    private func url(for id: UUID) -> URL? {
        directory?.appending(path: "\(id.uuidString).jpg")
    }

    public func image(for id: UUID) -> CGImage? {
        _ = revision
        if let cached = cache[id] { return cached }
        guard let url = url(for: id),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache[id] = image
        return image
    }

    public func save(_ image: CGImage, for id: UUID) {
        guard let scaled = Self.downscaled(image, maximumDimension: Self.maximumDimension) else { return }
        if let destinationURL = url(for: id) {
            guard Self.write(scaled, to: destinationURL) else { return }
        }
        cache[id] = scaled
        revision += 1
    }

    private static func write(_ image: CGImage, to destinationURL: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return false }
        // Previews show remote screen contents; keep them out of backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = destinationURL
        try? mutableURL.setResourceValues(values)
        return true
    }

    public func remove(for id: UUID) {
        if let url = url(for: id) {
            try? FileManager.default.removeItem(at: url)
        }
        cache[id] = nil
        revision += 1
    }

    public func removeAll() {
        if let directory, let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        cache.removeAll()
        revision += 1
    }

    static func downscaled(_ image: CGImage, maximumDimension: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let ratio = min(1, Double(maximumDimension) / Double(longest))
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Encodes screenshots for saving and sharing.
public enum ScreenshotEncoder {
    /// PNG data for an image, tagged with the pixel density it was captured at
    /// so it opens at the right physical size.
    public static func pngData(_ image: CGImage, scale: CGFloat = 2) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72.0 * Double(max(1, scale))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    public static func fileName(for computerName: String, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeName = computerName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
        return "\(safeName) \(formatter.string(from: date)).png"
    }
}
