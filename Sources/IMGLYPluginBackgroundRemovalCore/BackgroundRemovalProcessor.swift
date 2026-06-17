import IMGLYEditor
import IMGLYEngine
import UIKit

// MARK: - Background Removal Processor

@MainActor
enum BackgroundRemovalProcessor {
  private static let cacheSubdirectory = "ly.img.plugin.backgroundRemoval/results"

  static func process(context: Dock.Context, provider: any BackgroundRemovalProvider) async throws {
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

      let processedImage = try await provider.removeBackground(
        from: originalImage.fixOrientation(),
      )
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
      throw BackgroundRemovalError.imageSavingFailed("Failed to encode the processed image as PNG.")
    }
    do {
      let cacheDirectory = try FileManager.default
        .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent(cacheSubdirectory, isDirectory: true)
      try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
      let cacheURL = cacheDirectory.appendingPathComponent(UUID().uuidString, conformingTo: .png)
      try imageData.write(to: cacheURL)
      return cacheURL
    } catch {
      throw BackgroundRemovalError.imageSavingFailed(error.localizedDescription)
    }
  }
}

// MARK: - UIImage orientation helper

extension UIImage {
  /// Returns a copy of the image rotated so the pixel buffer matches the
  /// visual orientation.
  func fixOrientation() -> UIImage {
    guard imageOrientation != .up else { return self }
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
      draw(at: .zero)
    }
  }
}
