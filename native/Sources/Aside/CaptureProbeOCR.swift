import CoreGraphics
import Foundation
import Vision

struct CaptureProbeImageFormat: Codable, Sendable {
  var width: Int
  var height: Int
  var bitsPerComponent: Int
  var bitsPerPixel: Int
  var bytesPerRow: Int
  var bitmapInfo: UInt32
  var alphaInfo: UInt32
  var colorSpaceModel: Int
  var colorSpaceComponents: Int
  var hasDataProvider: Bool
  init(_ image: CGImage) {
    width = image.width
    height = image.height
    bitsPerComponent = image.bitsPerComponent
    bitsPerPixel = image.bitsPerPixel
    bytesPerRow = image.bytesPerRow
    bitmapInfo = image.bitmapInfo.rawValue
    alphaInfo = image.alphaInfo.rawValue
    colorSpaceModel = image.colorSpace.map { Int($0.model.rawValue) } ?? -1
    colorSpaceComponents = image.colorSpace?.numberOfComponents ?? 0
    hasDataProvider = image.dataProvider != nil
  }
}
struct CaptureProbeOCRError: Codable, Sendable {
  var sample: Int
  var operation: String
  var domain: String
  var code: Int
  var sourceFormat: CaptureProbeImageFormat
  var normalizedFormat: CaptureProbeImageFormat?
}
struct CaptureProbeOCRResult {
  var markerVisible: Bool?
  var numberedMarkerVisible: Bool?
  var error: CaptureProbeOCRError?
}

/// Eagerly rasterize only the Vision input. ROI comparison retains its original path.
/// No input/output pixels or recognized text leave this in-memory function.
@MainActor
enum CaptureProbeOCR {
  static func inspect(_ image: CGImage, marker: String, suffix: Int, sample: Int)
    -> CaptureProbeOCRResult
  {
    let originalFormat = CaptureProbeImageFormat(image)
    var normalizedFormat: CaptureProbeImageFormat?
    var operation = "normalize"
    do {
      let bitmap = try normalizedBitmap(image)
      normalizedFormat = CaptureProbeImageFormat(bitmap)
      operation = "recognize"
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = false
      try VNImageRequestHandler(cgImage: bitmap, options: [:]).perform([request])
      let plain = marker.uppercased()
      let numbered = "\(marker) \(suffix)".uppercased()
      var markerVisible = false
      var numberedVisible = false
      for item in request.results ?? [] {
        guard let text = item.topCandidates(1).first?.string.uppercased() else { continue }
        markerVisible = markerVisible || text.contains(plain)
        numberedVisible = numberedVisible || text.contains(numbered)
      }
      return CaptureProbeOCRResult(
        markerVisible: markerVisible, numberedMarkerVisible: numberedVisible)
    } catch {
      let error = error as NSError
      return CaptureProbeOCRResult(
        error: CaptureProbeOCRError(
          sample: sample, operation: operation,
          domain: error.domain, code: error.code, sourceFormat: originalFormat,
          normalizedFormat: normalizedFormat))
    }
  }
  private static func normalizedBitmap(_ image: CGImage) throws -> CGImage {
    guard image.width > 0, image.height > 0,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw AsideError("Could not allocate a standard 8-bit RGB OCR bitmap") }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(rect)
    context.interpolationQuality = .none
    context.draw(image, in: rect)
    guard let result = context.makeImage() else {
      throw AsideError("Could not snapshot the standard OCR bitmap")
    }
    return result
  }
}
