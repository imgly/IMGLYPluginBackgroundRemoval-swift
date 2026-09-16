import Foundation

/// Errors thrown by the background removal workflow.
public enum BackgroundRemovalError: LocalizedError, Sendable {
  /// No active page was found in the current scene.
  case noPageFound
  /// The current page's fill is not an image.
  case noImageFound(currentType: String)
  /// The image fill has no source URI.
  case noImageSourceFound
  /// The image data could not be decoded.
  case imageConversionFailed
  /// The provider could not segment the foreground from the background.
  case backgroundRemovalFailed
  /// The processed image could not be saved.
  case imageSavingFailed(String)
  /// The model file could not be located.
  case modelNotFound(String)
  /// The model download failed.
  case modelDownloadFailed(String)
  /// The inference engine reported a runtime error.
  case inferenceFailed(String)
  /// The mask could not be composited onto the image.
  case compositingFailed(String)

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
      "AI background removal failed. Please ensure the image contains a clearly visible subject."
    case let .imageSavingFailed(message):
      "Failed to save the processed image: \(message)"
    case let .modelNotFound(message):
      "Model not found: \(message)"
    case let .modelDownloadFailed(message):
      "Failed to download the segmentation model: \(message)"
    case let .inferenceFailed(message):
      "Background removal inference failed: \(message)"
    case let .compositingFailed(message):
      "Failed to composite the segmentation mask onto the image: \(message)"
    }
  }
}
