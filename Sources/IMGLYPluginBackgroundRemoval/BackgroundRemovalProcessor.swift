import IMGLYEditor
import IMGLYEngine
import UIKit

// MARK: - Background Removal Processor

/// Handles the background removal workflow: extract image, process, replace.
@MainActor
enum BackgroundRemovalProcessor {
  /// Performs background removal on the current page's image fill.
  /// - Throws: `BackgroundRemovalError` describing what went wrong.
  static func process(context: Dock.Context) async throws {
    let engine = context.engine

    guard let currentPage = try engine.scene.getCurrentPage() else {
      throw BackgroundRemovalError.noPageFound
    }

    let imageFill = try engine.block.getFill(currentPage)
    let fillType = try engine.block.getType(imageFill)
    guard fillType == FillType.image.rawValue else {
      throw BackgroundRemovalError.noImageFound(currentType: fillType)
    }

    try engine.block.setState(imageFill, state: .pending(progress: 0.5))

    do {
      let imageData = try await extractImageData(from: imageFill, engine: engine)

      guard let originalImage = UIImage(data: imageData) else {
        throw BackgroundRemovalError.imageConversionFailed
      }

      guard let processedImage = await BackgroundRemover.removeBackground(
        from: originalImage.fixOrientation(),
      ) else {
        throw BackgroundRemovalError.backgroundRemovalFailed
      }

      let processedURL = try saveImageToCache(processedImage)

      try await engine.block.addImageFileURIToSourceSet(
        imageFill,
        property: "fill/image/sourceSet",
        uri: processedURL,
      )

      try engine.editor.addUndoStep()
      try engine.block.setState(imageFill, state: .ready)
    } catch {
      // Ensure the fill is restored to a ready state even on failure.
      try? engine.block.setState(imageFill, state: .ready)
      throw error
    }
  }

  // MARK: - Private

  private static func extractImageData(from block: DesignBlockID, engine: Engine) async throws -> Data {
    let imageFileURI = try engine.block.getString(block, property: "fill/image/imageFileURI")
    guard let url = URL(string: imageFileURI) else {
      throw BackgroundRemovalError.noImageSourceFound
    }
    let (data, _) = try await URLSession.shared.data(from: url)
    return data
  }

  private static func saveImageToCache(_ image: UIImage) throws -> URL {
    guard let imageData = image.pngData() else {
      throw BackgroundRemovalError.imageSavingFailed
    }
    let cacheURL = try FileManager.default
      .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
      .appendingPathComponent(UUID().uuidString, conformingTo: .png)
    try imageData.write(to: cacheURL)
    return cacheURL
  }
}

// MARK: - Errors

/// Errors emitted by ``BackgroundRemovalPlugin`` when the background removal workflow fails.
public enum BackgroundRemovalError: LocalizedError, Sendable {
  /// No active page was found in the current scene.
  case noPageFound
  /// The current page's fill is not an image.
  case noImageFound(currentType: String)
  /// The image fill has no source URI to download from.
  case noImageSourceFound
  /// The downloaded data could not be converted to a `UIImage`.
  case imageConversionFailed
  /// The Vision framework failed to segment the person from the background.
  case backgroundRemovalFailed
  /// The processed image could not be saved to the cache directory.
  case imageSavingFailed

  public var errorDescription: String? {
    switch self {
    case .noPageFound:
      "No active page found in the editor."
    case let .noImageFound(currentType):
      "The current page doesn't contain an image. Current content type: \(currentType)"
    case .noImageSourceFound:
      "No image source found for background removal."
    case .imageConversionFailed:
      "Failed to convert image data for processing."
    case .backgroundRemovalFailed:
      "AI background removal failed. Please ensure the image contains a clearly visible person."
    case .imageSavingFailed:
      "Failed to save the processed image."
    }
  }
}
