@preconcurrency import CoreImage
import IMGLYPluginBackgroundRemovalCore
import UIKit

// MARK: - Provider

/// IMG.LY's IS-Net foreground segmentation backend.
public struct IMGLYBackgroundRemovalProvider: BackgroundRemovalProvider {
  private let loader: SessionLoader
  private let loadMode: IMGLYBackgroundRemovalConfiguration.LoadMode

  /// Creates the provider.
  /// - Parameters:
  ///   - modelBaseURL: Where to fetch the model from.
  ///   - model: The model variant to use.
  ///   - loadMode: When to fetch and compile the model.
  public init(
    modelBaseURL: URL = IMGLYBackgroundRemovalConfiguration.defaultModelBaseURL,
    model: IMGLYBackgroundRemovalConfiguration.Model = .fp16,
    loadMode: IMGLYBackgroundRemovalConfiguration.LoadMode = .eager,
  ) {
    loader = SessionLoader(modelBaseURL: modelBaseURL, model: model)
    self.loadMode = loadMode
  }

  public func prewarm() async throws {
    guard loadMode == .eager else { return }
    try await loader.prewarm()
  }

  public func removeBackground(from image: UIImage) async throws -> UIImage {
    let session = try await loader.session()
    try Task.checkCancellation()

    guard let cgImage = image.cgImage else {
      throw BackgroundRemovalError.imageConversionFailed
    }

    let inputTensor = try Preprocessing.encode(cgImage)
    try Task.checkCancellation()

    let maskFloats = try await session.run(input: inputTensor)
    try Task.checkCancellation()

    guard let maskCGImage = Preprocessing.decodeMask(maskFloats) else {
      throw BackgroundRemovalError.compositingFailed("Could not convert mask floats to image")
    }
    return try Compositor.shared.apply(mask: maskCGImage, to: image)
  }
}

// MARK: - SessionLoader

/// Serializes the model download and CoreML compilation so concurrent
/// callers share one in-flight task.
private actor SessionLoader {
  private let modelBaseURL: URL
  private let model: IMGLYBackgroundRemovalConfiguration.Model
  private var sessionTask: Task<ONNXSession, Error>?

  init(modelBaseURL: URL, model: IMGLYBackgroundRemovalConfiguration.Model) {
    self.modelBaseURL = modelBaseURL
    self.model = model
  }

  func session() async throws -> ONNXSession {
    let task = sessionTask ?? Task<ONNXSession, Error> { [modelBaseURL, model] in
      let modelURL = try await ModelDownloader.resolve(modelBaseURL: modelBaseURL, model: model)
      return ONNXSession(modelURL: modelURL, model: model)
    }
    sessionTask = task
    do {
      return try await task.value
    } catch {
      // Don't cache a failed download/compile — allow the next caller to retry.
      // Guard against clearing a newer task that replaced ours while we awaited.
      if sessionTask == task {
        sessionTask = nil
      }
      throw error
    }
  }

  func prewarm() async throws {
    let session = try await session()
    try await session.prewarm()
  }
}

// MARK: - Compositor

/// Composites the segmentation mask onto the original image.
private final class Compositor: @unchecked Sendable {
  static let shared = Compositor()

  private let context: CIContext

  private init() {
    context = CIContext(options: [
      .useSoftwareRenderer: false,
      .cacheIntermediates: false,
    ])
  }

  func apply(mask: CGImage, to original: UIImage) throws -> UIImage {
    // Composite in the raw pixel-buffer coordinate space and apply EXIF
    // orientation last so the mask aligns with the source.
    guard let rawCG = original.cgImage else {
      throw BackgroundRemovalError.imageConversionFailed
    }
    let rawCI = CIImage(cgImage: rawCG)

    let maskCI = CIImage(cgImage: mask)
    let scaleX = rawCI.extent.width / maskCI.extent.width
    let scaleY = rawCI.extent.height / maskCI.extent.height
    let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

    guard let blendFilter = CIFilter(name: "CIBlendWithRedMask") else {
      throw BackgroundRemovalError.compositingFailed("CIBlendWithRedMask filter unavailable")
    }
    blendFilter.setValue(rawCI, forKey: kCIInputImageKey)
    blendFilter.setValue(
      CIImage(color: .clear).cropped(to: rawCI.extent),
      forKey: kCIInputBackgroundImageKey,
    )
    blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)

    guard let blended = blendFilter.outputImage else {
      throw BackgroundRemovalError.compositingFailed("Failed to composite mask onto image")
    }

    let oriented = blended.oriented(forExifOrientation: Int32(original.imageOrientation.exifValue))

    guard let resultCG = context.createCGImage(oriented, from: oriented.extent) else {
      throw BackgroundRemovalError.compositingFailed("Failed to render composited image")
    }
    return UIImage(cgImage: resultCG)
  }
}

// MARK: - UIImage Orientation -> EXIF

private extension UIImage.Orientation {
  var exifValue: Int {
    switch self {
    case .up: 1
    case .down: 3
    case .left: 8
    case .right: 6
    case .upMirrored: 2
    case .downMirrored: 4
    case .leftMirrored: 5
    case .rightMirrored: 7
    @unknown default: 1
    }
  }
}
