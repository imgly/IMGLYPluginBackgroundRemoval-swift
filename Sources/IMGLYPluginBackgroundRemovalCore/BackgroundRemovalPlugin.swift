import IMGLYEditor
import IMGLYEngine
import OSLog
import SwiftUI

// MARK: - Logger

extension Logger {
  static let plugin = Logger(subsystem: "ly.img.plugin.backgroundRemoval", category: "BackgroundRemovalPlugin")
}

// MARK: - Background Removal Plugin

/// Adds AI-powered background removal to the editor.
///
/// The dock button removes the background of the current page's image. The inspector bar button, which
/// `inspectorBarModifier` adds, removes the background of the selected image or page, and is hidden for
/// stickers. Each button is only visible when its block has an image fill that is not SVG, and its scope
/// allows a fill change. Several images can be processed at once, and the model runs on one image at a time.
///
/// The results are PNG files in the app's caches directory, which iOS can clear. To keep them, upload the `file://`
/// URLs that `engine.editor.findAllMediaURIs()` returns, and point the scene to the uploads with `relocateResource`.
@MainActor
public final class BackgroundRemovalPlugin: EditorConfiguration {
  private let provider: any BackgroundRemovalProvider
  private let runner: Runner
  private let inspectorBarModifier: @MainActor @Sendable (
    _ items: InspectorBar.Modifier,
    _ button: any InspectorBar.Item,
  ) -> Void
  private let dockModifier: @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item) -> Void

  // A second initializer, not a default value for `inspectorBarModifier`: Swift 6 binds an unlabeled trailing
  // closure after `onError:` to the next closure parameter, which must stay `dockModifier`.
  /// Creates the plugin without an inspector bar button.
  ///
  /// - Parameters:
  ///   - configuration: The background removal backend to use.
  ///   - onError: Called when background removal fails. If `nil`, errors
  ///     are logged.
  ///   - dockModifier: Inserts the plugin's dock button into the dock.
  ///     Defaults to prepending it.
  public convenience init(
    configuration: any BackgroundRemovalConfiguration,
    onError: (@MainActor @Sendable (Error) -> Void)? = nil,
    dockModifier: @escaping @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item)
      -> Void = { items, button in
        items.addFirst { button }
      },
  ) {
    self.init(
      configuration: configuration,
      onError: onError,
      inspectorBarModifier: { _, _ in },
      dockModifier: dockModifier,
    )
  }

  /// Creates the plugin.
  ///
  /// - Parameters:
  ///   - configuration: The background removal backend to use.
  ///   - onError: Called when background removal fails. If `nil`, errors
  ///     are logged.
  ///   - inspectorBarModifier: Inserts the plugin's inspector bar button into
  ///     the inspector bar, for example with `items.addFirst { button }`.
  ///   - dockModifier: Inserts the plugin's dock button into the dock.
  ///     Defaults to prepending it.
  public init(
    configuration: any BackgroundRemovalConfiguration,
    onError: (@MainActor @Sendable (Error) -> Void)? = nil,
    inspectorBarModifier: @escaping @MainActor @Sendable (
      _ items: InspectorBar.Modifier,
      _ button: any InspectorBar.Item,
    ) -> Void,
    dockModifier: @escaping @MainActor @Sendable (_ items: Dock.Modifier, _ button: any Dock.Item)
      -> Void = { items, button in
        items.addFirst { button }
      },
  ) {
    let provider = configuration.provider
    self.provider = provider
    runner = Runner(provider: provider, errorHandler: onError)
    self.inspectorBarModifier = inspectorBarModifier
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

  private var dockButton: any Dock.Item {
    let runner = runner
    return Dock.Button(
      id: "ly.img.plugin.backgroundRemoval",
      action: { context in
        runner.removeBackground(of: try? context.engine.scene.getCurrentPage(), engine: context.engine)
      },
      label: { _ in
        Label {
          Text(.backgroundRemovalDockButton)
        } icon: {
          Image(systemName: "person.and.background.dotted")
        }
      },
      isVisible: { context in
        guard let page = try? context.engine.scene.getCurrentPage() else { return false }
        return BackgroundRemovalProcessor.canProcess(page, engine: context.engine)
      },
    )
  }

  /// The dock configuration. Inserts the background removal button.
  override public var dock: Dock.Configuration? {
    let button = dockButton
    let dockModifier = dockModifier
    return Dock.Configuration { builder in
      builder.modify { _, items in
        dockModifier(items, button)
      }
    }
  }

  // MARK: - Inspector Bar

  private var inspectorBarButton: any InspectorBar.Item {
    let runner = runner
    return InspectorBar.Button(
      id: "ly.img.component.inspectorBar.button.backgroundRemoval",
      action: { context in
        runner.removeBackground(of: context.selection.block, engine: context.engine)
      },
      label: { _ in
        Label {
          Text(.backgroundRemovalInspectorBarButton)
        } icon: {
          Image(systemName: "person.and.background.dotted")
        }
      },
      isVisible: { context in
        context.selection.kind != "sticker" && context.selection.fillType == .image &&
          BackgroundRemovalProcessor.canProcess(context.selection.block, engine: context.engine)
      },
    )
  }

  /// The inspector bar configuration. Inserts the background removal button.
  override public var inspectorBar: InspectorBar.Configuration? {
    let button = inspectorBarButton
    let inspectorBarModifier = inspectorBarModifier
    return InspectorBar.Configuration { builder in
      builder.modify { _, items in
        inspectorBarModifier(items, button)
      }
    }
  }
}

// MARK: - Runner

private extension BackgroundRemovalPlugin {
  /// Runs one background removal for each block, and ignores a tap on a block that is processing already. The
  /// buttons capture the runner, not the plugin: the plugin keeps its buttons in its builder, so a button that
  /// captures the plugin keeps the plugin and its model alive.
  @MainActor
  final class Runner {
    private let provider: any BackgroundRemovalProvider
    private let errorHandler: (@MainActor @Sendable (Error) -> Void)?
    private let modelQueue = SerialQueue()
    private var processingBlocks: Set<DesignBlockID> = []

    init(provider: any BackgroundRemovalProvider, errorHandler: (@MainActor @Sendable (Error) -> Void)?) {
      self.provider = provider
      self.errorHandler = errorHandler
    }

    func removeBackground(of block: DesignBlockID?, engine: Engine) {
      guard let block else {
        report(BackgroundRemovalError.noPageFound)
        return
      }
      guard processingBlocks.insert(block).inserted else { return }
      // The editor closes by freeing its engine, so a removal holds the engine weakly.
      Task { [weak engine] in
        defer { processingBlocks.remove(block) }
        do {
          try await BackgroundRemovalProcessor.process(block, engine: { engine }, provider: provider,
                                                       queue: modelQueue)
        } catch {
          // A removal that fails because the editor closed is no error for the integrator.
          if engine != nil {
            report(error)
          }
        }
      }
    }

    private func report(_ error: Error) {
      if let errorHandler {
        errorHandler(error)
      } else {
        Logger.plugin.error("\(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
