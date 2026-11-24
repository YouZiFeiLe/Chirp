import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum DevicePairingImages {
    static let maxBytes = 8 * 1024 * 1024

    static func png(request: DevicePairingRequest) throws -> Data {
        try request.validate()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(try request.code.utf8); filter.correctionLevel = "M"
        guard let image = filter.outputImage else { throw DevicePairingError.invalidQR }
        let border = image.extent.insetBy(dx: -4, dy: -4)
        let background = CIImage(color: .white).cropped(to: border)
        let framed = image.composited(over: background).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        guard let bitmap = CIContext().createCGImage(framed, from: framed.extent) else { throw DevicePairingError.invalidQR }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw DevicePairingError.invalidQR }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { throw DevicePairingError.invalidQR }
        return data as Data
    }

    static func request(fromImage data: Data) throws -> DevicePairingRequest {
        guard data.count <= maxBytes else { throw DevicePairingError.imageTooLarge }
        let decodeOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, decodeOptions),
              let identifier = CGImageSourceGetType(source) as String?,
              UTType(identifier)?.conforms(to: .image) == true,
              CGImageSourceGetCount(source) > 0 else { throw DevicePairingError.invalidQR }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw DevicePairingError.invalidQR }
        guard (1...4096).contains(width), (1...4096).contains(height) else { throw DevicePairingError.imageTooLarge }
        guard let image = CGImageSourceCreateImageAtIndex(source, index, decodeOptions) else { throw DevicePairingError.invalidQR }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let scan = VNDetectBarcodesRequest()
        scan.symbologies = [.qr]
        let payloads: [String?]
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        if (try? handler.perform([scan])) != nil, let results = scan.results, !results.isEmpty {
            payloads = results.map(\.payloadStringValue)
        } else {
            // Core Image can read QR codes when Vision's detector is unavailable.
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let oriented = CIImage(cgImage: image).oriented(orientation)
            payloads = (detector?.features(in: oriented) ?? []).map { ($0 as? CIQRCodeFeature)?.messageString }
        }
        guard payloads.count == 1, let value = payloads[0] else { throw DevicePairingError.noQRCode }
        return try DevicePairingRequest.parse(value)
    }

    static func request(fromImage url: URL) throws -> DevicePairingRequest {
        #if os(macOS)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        #endif
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maxBytes else { throw DevicePairingError.imageTooLarge }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        guard let data = try file.read(upToCount: maxBytes + 1) else { throw DevicePairingError.invalidQR }
        return try request(fromImage: data)
    }
}
