import IMGLYPluginBackgroundRemovalCore

/// Configures the Apple Vision-based background removal backend.
///
/// People-only — emits a mask only when at least one face or body is
/// detected in the frame.
public struct VisionBackgroundRemovalConfiguration: BackgroundRemovalConfiguration {
  /// The Apple Vision provider built by this configuration.
  public let provider: any BackgroundRemovalProvider

  /// Creates a configuration.
  public init() {
    provider = VisionBackgroundRemovalProvider()
  }
}
