import Accelerate
import CoreGraphics
import IMGLYPluginBackgroundRemovalCore

/// Image ↔ tensor conversion for the IS-Net model.
enum Preprocessing {
  /// IS-Net model input dimensions.
  static let modelInputSize = 1024

  // MARK: - Encode

  /// Converts a `CGImage` to the Float32 BCHW tensor the IS-Net model expects.
  static func encode(_ cgImage: CGImage) throws -> [Float] {
    let size = modelInputSize
    let pixelCount = size * size
    let bytesPerRow = size * 4

    // Render the image into an RGBX buffer at the model input size.
    var pixelData = [UInt8](repeating: 0, count: size * bytesPerRow)
    guard let context = pixelData.withUnsafeMutableBytes({ bytes in
      CGContext(
        data: bytes.baseAddress,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
      )
    }) else {
      throw BackgroundRemovalError.inferenceFailed("Failed to create CGContext for preprocessing")
    }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

    let interleavedFloats: [Float] = vDSP.integerToFloatingPoint(
      pixelData,
      floatingPointType: Float.self,
    )

    // Normalize `(pixel - 128) / 256` per channel from the strided
    // interleaved source into the packed planar output.
    var result = [Float](repeating: 0, count: 3 * pixelCount)
    var scale: Float = 1.0 / 256.0
    var bias: Float = -0.5

    interleavedFloats.withUnsafeBufferPointer { srcBuf in
      result.withUnsafeMutableBufferPointer { dstBuf in
        guard let src = srcBuf.baseAddress, let dst = dstBuf.baseAddress else { return }
        for channel in 0 ..< 3 {
          vDSP_vsmsa(
            src.advanced(by: channel),
            4,
            &scale,
            &bias,
            dst.advanced(by: channel * pixelCount),
            1,
            vDSP_Length(pixelCount),
          )
        }
      }
    }
    return result
  }

  // MARK: - Decode

  /// Converts the model's Float32 mask output (`[0..1]`) to a grayscale `CGImage`.
  static func decodeMask(_ maskData: [Float]) -> CGImage? {
    let size = modelInputSize
    let pixelCount = size * size
    let length = min(maskData.count, pixelCount)
    guard length > 0 else { return nil }

    // Scale [0..1] to [0..255], clamp, convert Float → UInt8.
    var scaled = [Float](repeating: 0, count: length)
    var scale: Float = 255
    vDSP_vsmul(maskData, 1, &scale, &scaled, 1, vDSP_Length(length))
    var lower: Float = 0
    var upper: Float = 255
    vDSP_vclip(scaled, 1, &lower, &upper, &scaled, 1, vDSP_Length(length))
    let pixelsFilled: [UInt8] = vDSP.floatingPointToInteger(
      scaled,
      integerType: UInt8.self,
      rounding: .towardNearestInteger,
    )
    var pixels = [UInt8](repeating: 0, count: pixelCount)
    pixels.replaceSubrange(0 ..< length, with: pixelsFilled)

    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: size,
      height: size,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: size,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: 0),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent,
    )
  }
}
