import IMGLYEditor

public extension BackgroundRemovalPlugin {
  /// Creates the plugin with the default IMG.LY ONNX backend.
  ///
  /// - Parameters:
  ///   - onError: Called when background removal fails. If `nil`, errors are
  ///     logged via the plugin's `os.Logger`.
  ///   - dockModifier: Inserts the plugin's dock button into the dock.
  ///     Defaults to prepending it.
  convenience init(
    onError: (@MainActor @Sendable (Error) -> Void)? = nil,
    dockModifier: @escaping @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item)
      -> Void = { items, button in
        items.addFirst { button }
      },
  ) {
    self.init(
      configuration: IMGLYBackgroundRemovalConfiguration(),
      onError: onError,
      dockModifier: dockModifier,
    )
  }
}
