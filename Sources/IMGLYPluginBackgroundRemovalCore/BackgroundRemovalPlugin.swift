import IMGLYEditor
import IMGLYEngine
import OSLog
import SwiftUI

// MARK: - Logger

extension Logger {
  static let plugin = Logger(subsystem: "ly.img.plugin.backgroundRemoval", category: "BackgroundRemovalPlugin")
}

// MARK: - Background Removal Plugin

/// Adds AI-powered background removal to the editor dock.
@MainActor
public final class BackgroundRemovalPlugin: EditorConfiguration {
  private let provider: any BackgroundRemovalProvider
  private let errorHandler: (@MainActor @Sendable (Error) -> Void)?
  private let dockModifier: @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item) -> Void

  private var isProcessing = false

  /// Creates the plugin.
  ///
  /// - Parameters:
  ///   - configuration: The background removal backend to use.
  ///   - onError: Called when background removal fails. If `nil`, errors
  ///     are logged.
  ///   - dockModifier: Inserts the plugin's dock button into the dock.
  ///     Defaults to prepending it.
  public init(
    configuration: any BackgroundRemovalConfiguration,
    onError: (@MainActor @Sendable (Error) -> Void)? = nil,
    dockModifier: @escaping @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item)
      -> Void = { items, button in
        items.addFirst { button }
      },
  ) {
    provider = configuration.provider
    errorHandler = onError
    self.dockModifier = dockModifier
    super.init()
  }

  // MARK: - Lifecycle

  /// The `onCreate` handler. Triggers the provider's warm-up hook.
  override public var onCreate: OnCreate.Handler? {
    let provider = provider
    return { _, existing in
      try await existing()
      // Detached so prewarm's network + CoreML compilation work doesn't
      // pin the editor's `onCreate` actor — the editor finishes presenting
      // while the model loads in the background.
      // swiftlint:disable:next task_detached
      Task.detached(priority: .background) {
        do {
          try await provider.prewarm()
        } catch {
          // First user-facing `removeBackground` call retries and surfaces
          // any persistent failure via the plugin's `onError`.
          Logger.plugin.error("Prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
  }

  // MARK: - Dock

  private var button: any Dock.Item {
    let provider = provider
    let errorHandler = errorHandler
    return Dock.Button(
      id: "ly.img.plugin.backgroundRemoval",
      action: { context in
        Task {
          guard !self.isProcessing else { return }
          self.isProcessing = true
          defer { self.isProcessing = false }
          do {
            try await BackgroundRemovalProcessor.process(context: context, provider: provider)
          } catch {
            if let errorHandler {
              errorHandler(error)
            } else {
              Logger.plugin.error("\(error.localizedDescription, privacy: .public)")
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

  /// The dock configuration. Inserts the background removal button.
  override public var dock: Dock.Configuration? {
    let button = button
    let dockModifier = dockModifier
    return Dock.Configuration { builder in
      builder.modify { _, items in
        dockModifier(items, button)
      }
    }
  }
}
