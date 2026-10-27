import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

// Independently implemented image utilities. No FlowShelf source is included.
enum ImageWorkbenchError: LocalizedError {
  case invalidImage, tooLarge, noText, noQR, exportFailed
  var errorDescription: String? {
    let key: String
    switch self {
    case .invalidImage: key = "The image could not be opened."
    case .tooLarge: key = "The result is too large. Use smaller images (maximum 32 megapixels)."
    case .noText: key = "No text was found in this image."
    case .noQR: key = "No QR code was found in this image."
    case .exportFailed: key = "The image could not be exported."
    }
    return NSLocalizedString(key, comment: "Image tools error")
  }
}

enum ImageWorkbench {
  static let pixelLimit = 32_000_000

  static func validate(width: Int, height: Int) throws {
    guard width > 0, height > 0 else { throw ImageWorkbenchError.invalidImage }
    guard width <= 16384, height <= 16384, width <= pixelLimit / height else {
      throw ImageWorkbenchError.tooLarge
    }
  }

  static func decode(_ data: Data, maximumDimension: Int = 8192) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else { throw ImageWorkbenchError.invalidImage }
    try validate(width: image.width, height: image.height)
    return image
  }

  static func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw ImageWorkbenchError.exportFailed
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw ImageWorkbenchError.exportFailed }
    return data as Data
  }

  static func render(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
    try validate(width: width, height: height)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw ImageWorkbenchError.exportFailed
    }
    ctx.interpolationQuality = .high
    draw(ctx)
    guard let result = ctx.makeImage() else { throw ImageWorkbenchError.exportFailed }
    return result
  }

  static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    try render(width: width, height: height) { $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
  }

  static func rotated(_ image: CGImage) throws -> CGImage {
    try render(width: image.height, height: image.width) { ctx in
      ctx.translateBy(x: CGFloat(image.height), y: 0)
      ctx.rotate(by: .pi / 2)
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
  }

  static func flipped(_ image: CGImage) throws -> CGImage {
    try render(width: image.width, height: image.height) { ctx in
      ctx.translateBy(x: CGFloat(image.width), y: 0)
      ctx.scaleBy(x: -1, y: 1)
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
  }

  static func grayscale(_ image: CGImage) throws -> CGImage {
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
      throw ImageWorkbenchError.exportFailed
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let result = ctx.makeImage() else { throw ImageWorkbenchError.exportFailed }
    return result
  }

  static func combined(_ images: [CGImage], vertical: Bool, gap: Int = 12) throws -> CGImage {
    guard images.count >= 2 else { throw ImageWorkbenchError.invalidImage }
    let width = vertical ? images.map(\.width).max()! : images.reduce(0) { $0 + $1.width } + gap * (images.count - 1)
    let height = vertical ? images.reduce(0) { $0 + $1.height } + gap * (images.count - 1) : images.map(\.height).max()!
    return try render(width: width, height: height) { ctx in
      ctx.setFillColor(CGColor(gray: 1, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
      var offset = 0
      for image in images {
        let x = vertical ? (width - image.width) / 2 : offset
        let y = vertical ? height - offset - image.height : (height - image.height) / 2
        ctx.draw(image, in: CGRect(x: x, y: y, width: image.width, height: image.height))
        offset += (vertical ? image.height : image.width) + gap
      }
    }
  }

  // Both frames have the same canvas; preserve aspect ratio instead of stretching.
  static func gif(_ first: CGImage, _ second: CGImage) throws -> Data {
    let width = max(first.width, second.width), height = max(first.height, second.height)
    try validate(width: width, height: height)
    let output = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(output, UTType.gif.identifier as CFString, 2, nil) else {
      throw ImageWorkbenchError.exportFailed
    }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for image in [first, second] {
      let frame = try render(width: width, height: height) { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
      }
      CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.8]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { throw ImageWorkbenchError.exportFailed }
    return output as Data
  }

  static func recognize(_ data: Data, qr: Bool) throws -> String {
    let image = try decode(data)
    let handler = VNImageRequestHandler(cgImage: image)
    if qr {
      let request = VNDetectBarcodesRequest()
      request.symbologies = [.qr]
      try handler.perform([request])
      let strings = request.results?.compactMap(\.payloadStringValue) ?? []
      guard !strings.isEmpty else { throw ImageWorkbenchError.noQR }
      return strings.joined(separator: "\n")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
    try handler.perform([request])
    let strings = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    guard !strings.isEmpty else { throw ImageWorkbenchError.noText }
    return strings.joined(separator: "\n")
  }
}
