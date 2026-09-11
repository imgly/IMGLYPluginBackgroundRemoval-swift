@preconcurrency import CoreImage
import UIKit
@preconcurrency import Vision

/// Background removal using Apple's Vision framework for person segmentation.
enum BackgroundRemover {
  // MARK: - Vision Requests

  private static let faceDetectionRequest: VNDetectFaceRectanglesRequest = {
    let request = VNDetectFaceRectanglesRequest()
    request.revision = VNDetectFaceRectanglesRequestRevision3
    return request
  }()

  private static let bodyDetectionRequest: VNDetectHumanRectanglesRequest = {
    let request = VNDetectHumanRectanglesRequest()
    request.revision = VNDetectHumanRectanglesRequestRevision2
    return request
  }()

  private static let personSegmentationRequest: VNGeneratePersonSegmentationRequest = {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .accurate
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    request.revision = VNGeneratePersonSegmentationRequestRevision1
    return request
  }()

  // MARK: - Public

  /// Removes the background from an image containing a person.
  /// - Parameter image: The input UIImage.
  /// - Returns: A UIImage with transparent background, or nil if processing fails.
  static func removeBackground(from image: UIImage) async -> UIImage? {
    guard let ciImage = CIImage(image: image) else { return nil }

    return await withCheckedContinuation { continuation in
      Task {
        guard let maskImage = await generatePersonMask(from: ciImage) else {
          continuation.resume(returning: nil)
          return
        }

        guard let resultCIImage = applyTransparencyMask(maskImage, to: ciImage) else {
          continuation.resume(returning: nil)
          return
        }

        guard let resultUIImage = convertToUIImage(resultCIImage) else {
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(returning: resultUIImage)
      }
    }
  }

  // MARK: - Private

  private static func generatePersonMask(from image: CIImage) async -> CIImage? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let requestHandler = VNSequenceRequestHandler()

        do {
          try requestHandler.perform([
            faceDetectionRequest,
            bodyDetectionRequest,
            personSegmentationRequest,
          ], on: image)

          let faces = faceDetectionRequest.results ?? []
          let bodies = bodyDetectionRequest.results ?? []

          guard !faces.isEmpty || !bodies.isEmpty else {
            continuation.resume(returning: nil)
            return
          }

          guard let maskPixelBuffer = personSegmentationRequest.results?.first?.pixelBuffer else {
            continuation.resume(returning: nil)
            return
          }

          var maskImage = CIImage(cvPixelBuffer: maskPixelBuffer)
          let scaleX = image.extent.size.width / maskImage.extent.size.width
          let scaleY = image.extent.size.height / maskImage.extent.size.height
          maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

          continuation.resume(returning: maskImage)

        } catch {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private static func applyTransparencyMask(_ mask: CIImage, to image: CIImage) -> CIImage? {
    guard let blendFilter = CIFilter(name: "CIBlendWithRedMask") else { return nil }

    blendFilter.setDefaults()
    blendFilter.setValue(image, forKey: kCIInputImageKey)
    blendFilter.setValue(CIImage(color: CIColor.clear).cropped(to: image.extent), forKey: kCIInputBackgroundImageKey)
    blendFilter.setValue(mask, forKey: kCIInputMaskImageKey)

    return blendFilter.outputImage
  }

  private static func convertToUIImage(_ ciImage: CIImage) -> UIImage? {
    let context = CIContext(options: [
      .useSoftwareRenderer: false,
      .highQualityDownsample: true,
    ])
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

// MARK: - UIImage Orientation Fix

extension UIImage {
  func fixOrientation() -> UIImage {
    guard imageOrientation != .up else { return self }
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
      draw(at: .zero)
    }
  }
}
