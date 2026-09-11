import IMGLYEditor
import IMGLYEngine
import SwiftUI

// MARK: - Background Removal Plugin

/// A plugin that adds AI-powered background removal to the editor dock.
///
/// Uses Apple's Vision framework for person segmentation and applies
/// the result back to the current page's image fill.
@MainActor
public final class BackgroundRemovalPlugin: EditorConfiguration {
  // MARK: - Options

  /// Plugin-specific configuration options.
  public struct Options: Sendable {
    /// Called on the main actor when background removal fails. Use this to surface errors
    /// to the user (e.g., via an alert or toast). If `nil`, errors are logged via `print`.
    public var onError: (@MainActor @Sendable (Error) -> Void)?

    /// Controls where the background removal button appears in the dock.
    /// Receives the dock modifier and the plugin's button.
    /// Defaults to prepending the button.
    public var dockModifier: @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item) -> Void

    /// Creates plugin options.
    /// - Parameters:
    ///   - onError: Called on the main actor when background removal fails. If `nil`, errors are logged via `print`.
    ///   - dockModifier: Controls where the button appears in the dock. Defaults to prepending.
    public init(
      onError: (@MainActor @Sendable (Error) -> Void)? = nil,
      dockModifier: @escaping @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item)
        -> Void = { items, button in
          items.addFirst { button }
        },
    ) {
      self.onError = onError
      self.dockModifier = dockModifier
    }
  }

  private let options: Options

  /// Tracks whether a background removal run is currently in progress. Button taps are
  /// ignored while `true` to avoid overlapping jobs on the same image.
  private var isProcessing = false

  /// Creates the plugin with the given options.
  /// - Parameter options: Plugin-specific configuration.
  public init(options: Options = Options()) {
    self.options = options
    super.init()
  }

  // MARK: - Dock

  private var button: any Dock.Item {
    let options = options
    return Dock.Button(
      id: "ly.img.plugin.backgroundRemoval",
      action: { context in
        Task { @MainActor in
          guard !self.isProcessing else { return }
          self.isProcessing = true
          defer { self.isProcessing = false }
          do {
            try await BackgroundRemovalProcessor.process(context: context)
          } catch {
            if let onError = options.onError {
              onError(error)
            } else {
              print("[BackgroundRemovalPlugin] \(error.localizedDescription)")
            }
          }
        }
      },
      label: { _ in
        Label {
          Text(.backgroundRemovalDockButton)
        } icon: {
          Image(systemName: "person.and.background.dotted")
        }
      },
    )
  }

  override public var dock: Dock.Configuration? {
    let button = button
    let dockModifier = options.dockModifier
    return Dock.Configuration { builder in
      builder.modify { _, items in
        dockModifier(items, button)
      }
    }
  }
}
