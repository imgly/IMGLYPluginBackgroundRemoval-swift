import Foundation
import IMGLYPluginBackgroundRemovalCore

/// Configures the IMG.LY ONNX-based background removal backend.
public struct IMGLYBackgroundRemovalConfiguration: BackgroundRemovalConfiguration {
  /// The model variant to use. Defaults to ``Model/fp16``.
  public let model: Model

  /// Base URL where the model is hosted. Defaults to IMG.LY's CDN.
  ///
  /// Pass a `file://` URL pointing at a directory that contains
  /// `{model.rawValue}` to ship a pre-bundled model with your app and
  /// skip the download. Pass a custom `https://` URL with the same
  /// layout to self-host.
  public let modelBaseURL: URL

  /// Controls when the model is fetched and compiled. Defaults to
  /// ``LoadMode/eager``.
  public let loadMode: LoadMode

  /// The provider built from the fields above.
  public let provider: any BackgroundRemovalProvider

  /// IMG.LY's CDN base URL for the background-removal model files.
  public static let defaultModelBaseURL = URL(
    string: "https://staticimgly.com/imgly/plugin-mobile-background-removal/1.0.0",
  )!

  /// Creates a configuration.
  /// - Parameters:
  ///   - model: The model variant to use.
  ///   - modelBaseURL: Where to fetch the model from.
  ///   - loadMode: When to fetch and compile the model.
  public init(
    model: Model = .fp16,
    modelBaseURL: URL = Self.defaultModelBaseURL,
    loadMode: LoadMode = .eager,
  ) {
    self.model = model
    self.modelBaseURL = modelBaseURL
    self.loadMode = loadMode
    provider = IMGLYBackgroundRemovalProvider(
      modelBaseURL: modelBaseURL,
      model: model,
      loadMode: loadMode,
    )
  }

  /// The IS-Net model variant.
  public enum Model: String, Sendable, CaseIterable {
    /// Full-precision FP32 model.
    case fp32 = "isnet.onnx"
    /// Half-precision FP16 model. Recommended default.
    case fp16 = "isnet_fp16.onnx"
  }

  /// Controls when the model is fetched and compiled.
  public enum LoadMode: Sendable {
    /// Load the model on first use.
    case lazy
    /// Load the model during plugin initialization.
    case eager
  }
}
