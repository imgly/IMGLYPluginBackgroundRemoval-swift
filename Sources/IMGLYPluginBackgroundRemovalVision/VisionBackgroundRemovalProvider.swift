@preconcurrency import CoreImage
import IMGLYPluginBackgroundRemovalCore
import UIKit
@preconcurrency import Vision

/// Apple Vision-based background removal backend. People-only.
public struct VisionBackgroundRemovalProvider: BackgroundRemovalProvider {
  private static let sharedCIContext = CIContext(options: [
    .useSoftwareRenderer: false,
    .highQualityDownsample: true,
  ])

  /// Creates the provider.
  public init() {}

  public func removeBackground(from image: UIImage) async throws -> UIImage {
    try Task.checkCancellation()
    // Work in raw pixel-buffer coordinates and apply EXIF orientation last so
    // Vision sees the same orientation it's told about and the segmentation
    // mask lines up with the source pixels.
    guard let cgImage = image.cgImage else {
      throw BackgroundRemovalError.imageConversionFailed
    }
    let ciImage = CIImage(cgImage: cgImage)
    let orientation = image.imageOrientation.cgImagePropertyOrientation

    guard let maskImage = try Self.generatePersonMask(from: ciImage, orientation: orientation) else {
      throw BackgroundRemovalError.backgroundRemovalFailed
    }
    try Task.checkCancellation()

    guard let resultCIImage = Self.applyTransparencyMask(maskImage, to: ciImage) else {
      throw BackgroundRemovalError.backgroundRemovalFailed
    }

    let oriented = resultCIImage.oriented(orientation)
    guard let resultCG = Self.sharedCIContext.createCGImage(oriented, from: oriented.extent) else {
      throw BackgroundRemovalError.backgroundRemovalFailed
    }
    return UIImage(cgImage: resultCG)
  }

  // MARK: - Private

  private static func generatePersonMask(
    from image: CIImage,
    orientation: CGImagePropertyOrientation,
  ) throws -> CIImage? {
    let faceDetection = VNDetectFaceRectanglesRequest()
    faceDetection.revision = VNDetectFaceRectanglesRequestRevision3

    let bodyDetection = VNDetectHumanRectanglesRequest()
    bodyDetection.revision = VNDetectHumanRectanglesRequestRevision2

    let personSegmentation = VNGeneratePersonSegmentationRequest()
    personSegmentation.qualityLevel = .accurate
    personSegmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    personSegmentation.revision = VNGeneratePersonSegmentationRequestRevision1

    let requestHandler = VNSequenceRequestHandler()
    try requestHandler.perform(
      [faceDetection, bodyDetection, personSegmentation],
      on: image,
      orientation: orientation,
    )

    let faces = faceDetection.results ?? []
    let bodies = bodyDetection.results ?? []
    guard !faces.isEmpty || !bodies.isEmpty else { return nil }
    guard let maskPixelBuffer = personSegmentation.results?.first?.pixelBuffer else { return nil }

    var maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)
    let scaleX = image.extent.size.width / maskImage.extent.size.width
    let scaleY = image.extent.size.height / maskImage.extent.size.height
    maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
    return maskImage
  }

  private static func applyTransparencyMask(_ mask: CIImage, to image: CIImage) -> CIImage? {
    guard let blendFilter = CIFilter(name: "CIBlendWithRedMask") else { return nil }

    blendFilter.setDefaults()
    blendFilter.setValue(image, forKey: kCIInputImageKey)
    blendFilter.setValue(CIImage(color: CIColor.clear).cropped(to: image.extent), forKey: kCIInputBackgroundImageKey)
    blendFilter.setValue(mask, forKey: kCIInputMaskImageKey)

    return blendFilter.outputImage
  }
}

// MARK: - UIImage Orientation -> CGImagePropertyOrientation

private extension UIImage.Orientation {
  var cgImagePropertyOrientation: CGImagePropertyOrientation {
    switch self {
    case .up: .up
    case .down: .down
    case .left: .left
    case .right: .right
    case .upMirrored: .upMirrored
    case .downMirrored: .downMirrored
    case .leftMirrored: .leftMirrored
    case .rightMirrored: .rightMirrored
    @unknown default: .up
    }
  }
}
