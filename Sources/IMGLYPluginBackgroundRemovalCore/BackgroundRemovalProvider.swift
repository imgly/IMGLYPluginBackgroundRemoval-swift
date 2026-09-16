import UIKit

/// A backend that performs background removal.
///
/// Adopt this protocol to plug in a custom backend. Pair your provider
/// with a ``BackgroundRemovalConfiguration`` conformer to make it usable
/// by ``BackgroundRemovalPlugin``.
public protocol BackgroundRemovalProvider: Sendable {
  /// Removes the background from `image` and returns the result with a
  /// transparent background.
  /// - Parameter image: The image to process.
  /// - Returns: The image with the background replaced by transparency.
  func removeBackground(from image: UIImage) async throws -> UIImage

  /// Optional warm-up hook called by ``BackgroundRemovalPlugin`` from its
  /// `onCreate` lifecycle. Override to absorb cold-start costs (model
  /// download, TLS handshake, auth-token fetch) before the first
  /// ``removeBackground(from:)`` call. The default implementation is a
  /// no-op.
  func prewarm() async throws
}

public extension BackgroundRemovalProvider {
  func prewarm() async throws {}
}
