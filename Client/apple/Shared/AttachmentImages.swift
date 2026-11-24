import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct AttachmentImage: @unchecked Sendable { let image: CGImage }

enum AttachmentImages {
    static func thumbnail(source url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ClientFailure(.attachmentInvalid) }
        try validate(source)
        for size in [256, 192, 128, 96] {
            let image = try image(source: source, maxPixels: size)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ClientFailure(.attachmentInvalid) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= AttachmentInfo.maxThumbnailBytes - 28 { return data as Data }
        }
        throw ClientFailure(.attachmentInvalid)
    }

    static func decode(_ data: Data, maxPixels: Int = 2048) throws -> AttachmentImage {
        guard data.count <= AttachmentInfo.maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ClientFailure(.attachmentInvalid) }
        try validate(source)
        return AttachmentImage(image: try image(source: source, maxPixels: maxPixels))
    }
    private static func validate(_ source: CGImageSource) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 60_000_000 / height else { throw ClientFailure(.attachmentInvalid) }
    }
    private static func image(source: CGImageSource, maxPixels: Int) throws -> CGImage {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ClientFailure(.attachmentInvalid) }
        return image
    }
}

func attachmentWork<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .utility, operation: operation)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
