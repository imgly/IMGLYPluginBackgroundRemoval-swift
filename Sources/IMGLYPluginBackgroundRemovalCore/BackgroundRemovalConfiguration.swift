/// Background removal configuration passed to ``BackgroundRemovalPlugin``.
///
/// Adopt this protocol to wire up a custom backend by pairing a
/// ``BackgroundRemovalProvider`` with whatever configuration shape your
/// backend needs.
public protocol BackgroundRemovalConfiguration: Sendable {
  /// The provider that performs background removal.
  var provider: any BackgroundRemovalProvider { get }
}
