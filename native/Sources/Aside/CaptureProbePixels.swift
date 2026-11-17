import AppKit

/// Numerical comparisons only. Reference and sample pixel arrays remain transient in memory.
struct CaptureProbeROIComparison: Codable, Sendable {
  var region: String
  var sample: Int
  var meanAbsoluteRGBDifference: Double
  var changedPixelFraction: Double
  var blackPixelFraction: Double
  var referenceBlackPixelFraction: Double
  var sampledPixelCount: Int
}

enum CaptureProbePixels {
  static func bytes(_ image: CGImage, rect: CGRect) throws -> [UInt8] {
    guard let crop = image.cropping(to: rect), crop.width > 0, crop.height > 0 else {
      throw AsideError("Generic ROI was outside the capture; comparison is inconclusive")
    }
    let side = 64
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
      guard
        let context = CGContext(
          data: storage.baseAddress, width: side, height: side,
          bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .none
      context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
      return true
    }
    guard drawn else { throw AsideError("Could not compare the generic capture ROI") }
    return pixels
  }
  static func compare(_ pixels: [UInt8], to reference: [UInt8], region: String, sample: Int)
    -> CaptureProbeROIComparison
  {
    let count = min(pixels.count, reference.count) / 4
    var totalDifference = 0
    var changed = 0
    var black = 0
    var referenceBlack = 0
    for pixel in 0..<count {
      let index = pixel * 4
      let differences = (0..<3).map { abs(Int(pixels[index + $0]) - Int(reference[index + $0])) }
      totalDifference += differences.reduce(0, +)
      if differences.contains(where: { $0 > 16 }) { changed += 1 }
      if (0..<3).allSatisfy({ pixels[index + $0] < 12 }) { black += 1 }
      if (0..<3).allSatisfy({ reference[index + $0] < 12 }) { referenceBlack += 1 }
    }
    return CaptureProbeROIComparison(
      region: region, sample: sample,
      meanAbsoluteRGBDifference: Double(totalDifference) / Double(max(1, count * 3)),
      changedPixelFraction: Double(changed) / Double(max(1, count)),
      blackPixelFraction: Double(black) / Double(max(1, count)),
      referenceBlackPixelFraction: Double(referenceBlack) / Double(max(1, count)),
      sampledPixelCount: count)
  }
}
