import IMGLYEngine
import UIKit

// MARK: - Background Removal Processor

@MainActor
enum BackgroundRemovalProcessor {
  private nonisolated static let cacheSubdirectory = "ly.img.plugin.backgroundRemoval/results"
  private static let readableSchemes: Set<String?> = ["http", "https", "file", "data", "buffer"]
  private static let imageFileURIProperty = "fill/image/imageFileURI"
  private static let previewFileURIProperty = "fill/image/previewFileURI"
  private static let sourceSetProperty = "fill/image/sourceSet"

  /// Whether the background of `block` can be removed: it has an image fill that is not SVG, and its scope
  /// allows a fill change.
  static func canProcess(_ block: DesignBlockID, engine: Engine) -> Bool {
    guard (try? engine.block.isAllowedByScope(block, key: "fill/change")) == true else {
      return false
    }
    return (try? imageSource(of: block, engine: engine)) != nil
  }

  /// Removes the background of the image of `block`. `queue` runs the model on one image at a time, so the memory
  /// peak does not grow with each image the user taps. `engine` returns `nil` once the editor freed its engine, so a
  /// removal keeps no closed editor alive and writes nothing into it.
  static func process(_ block: DesignBlockID, engine: @escaping @MainActor () -> Engine?,
                      provider: any BackgroundRemovalProvider, queue: SerialQueue) async throws {
    guard let source = try engine().map({ try imageSource(of: block, engine: $0) }) else {
      return
    }

    try engine()?.block.setState(source.fill, state: .pending(progress: 0.5))
    defer {
      try? engine()?.block.setState(source.fill, state: .ready)
    }

    // A removal that waits for the model would keep the loading state on an image that the user replaced, so a
    // change of the image, or a closed editor, ends the wait.
    let turn = Task {
      try await queue.waitForTurn()
    }
    let watcher = observe(block, showing: source, engine: engine) {
      turn.cancel()
    }
    let gotTurn = await turn.result
    watcher.cancel()
    guard case .success = gotTurn else {
      return
    }
    defer {
      queue.endTurn()
    }
    guard let result = try await maskedFiles(of: block, showing: source, engine: engine, provider: provider) else {
      return
    }
    let (current, files) = result
    guard let engine = engine(), image(of: block, ifItShows: source, engine: engine) != nil else {
      delete(files)
      return
    }
    try commit(files, of: current, engine: engine)
    try engine.editor.addUndoStep()
  }

  /// Runs the model on the image of `block` and writes the result as PNG files, or returns `nil` when the block
  /// shows another image than `source`. The user can delete the block or replace its image during each await, so the
  /// image is checked again before each step.
  private static func maskedFiles(of block: DesignBlockID, showing source: ImageSource,
                                  engine: @escaping @MainActor () -> Engine?,
                                  provider: any BackgroundRemovalProvider) async throws -> (ImageSource, ImageFiles)? {
    guard image(of: block, ifItShows: source, engine: engine()) != nil else {
      return nil
    }
    let originalImage = try await decode(imageData(at: source.url, engine: engine))
    guard image(of: block, ifItShows: source, engine: engine()) != nil else {
      return nil
    }
    let processedImage = try await provider.removeBackground(from: originalImage)
    guard let current = image(of: block, ifItShows: source, engine: engine()) else {
      return nil
    }
    return try await (current, savePNGs(of: processedImage, sizes: current.sourceSet.map(\.size)))
  }

  // MARK: - Private

  private struct ImageSource {
    let fill: DesignBlockID
    let url: URL
    let imageFileURI: String
    let sourceSet: [Source]
  }

  /// The processed image as PNG files: one at its own size, and one for each source set entry, in its order.
  private struct ImageFiles {
    let image: URL
    let sourceSet: [URL]
  }

  private static func imageSource(of block: DesignBlockID, engine: Engine) throws -> ImageSource {
    guard try engine.block.supportsFill(block) else {
      let blockType = try engine.block.getType(block)
      throw BackgroundRemovalError.noImageFound(currentType: blockType)
    }
    let fill = try engine.block.getFill(block)
    let fillType = try engine.block.getType(fill)
    guard fillType == FillType.image.rawValue else {
      throw BackgroundRemovalError.noImageFound(currentType: fillType)
    }
    let sourceSet = try engine.block.getSourceSet(fill, property: sourceSetProperty)
    let imageFileURI = try engine.block.getString(fill, property: imageFileURIProperty)
    // The engine draws the source set when the fill has one, and the image file otherwise.
    let url: URL? = if let largest = sourceSet.max(by: { $0.pixelCount < $1.pixelCount }) {
      largest.uri
    } else {
      URL(string: imageFileURI)
    }
    // `imageData(at:engine:)` reads only these schemes. A relative URI has none.
    guard let url, readableSchemes.contains(url.scheme?.lowercased()) else {
      throw BackgroundRemovalError.noImageSourceFound
    }
    // `UIImage` cannot decode SVG.
    guard try !isSVG(url, engine: engine) else {
      throw BackgroundRemovalError.imageConversionFailed
    }
    return ImageSource(fill: fill, url: url, imageFileURI: imageFileURI, sourceSet: sourceSet)
  }

  /// The image of `block` with its current source set, or `nil` when the block shows another image than `source`.
  /// The drawn URI decides, so an entry that the engine adds to the source set still counts as the same image.
  private static func image(of block: DesignBlockID, ifItShows source: ImageSource, engine: Engine?) -> ImageSource? {
    guard let engine, let current = try? imageSource(of: block, engine: engine), current.fill == source.fill,
          current.imageFileURI == source.imageFileURI, current.url == source.url else {
      return nil
    }
    return current
  }

  /// Calls `onChange` when `block` stops showing the image of `source`, or the editor frees its engine. It checks on a
  /// timer instead of subscribing to engine events, because a subscription keeps the native engine alive.
  private static func observe(_ block: DesignBlockID, showing source: ImageSource,
                              engine: @escaping @MainActor () -> Engine?,
                              onChange: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task {
      while !Task.isCancelled {
        guard image(of: block, ifItShows: source, engine: engine()) != nil else {
          onChange()
          return
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  /// An archive keeps each image in a buffer whose URI has no file extension, so the first bytes decide. A raster
  /// format starts with a binary signature, and SVG starts with `<`, after an optional BOM and whitespace.
  private static func isSVG(_ url: URL, engine: Engine) throws -> Bool {
    switch url.scheme?.lowercased() {
    case "data":
      return url.absoluteString.lowercased().hasPrefix("data:image/svg")
    case "buffer":
      let length = try min(64, engine.editor.getBufferLength(url: url).uintValue)
      let head = try engine.editor.getBufferData(url: url, offset: 0, length: length)
      let skipped: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF]
      return head.first { !skipped.contains($0) } == UInt8(ascii: "<")
    default:
      return url.pathExtension.lowercased() == "svg"
    }
  }

  /// Reads a `buffer://` image, such as one of a loaded archive, from the engine, and any other image from its URL.
  private static func imageData(at url: URL, engine: @MainActor () -> Engine?) async throws -> Data {
    guard url.scheme?.lowercased() == "buffer" else {
      return try await URLSession.shared.data(from: url).0
    }
    guard let engine = engine() else {
      throw CancellationError()
    }
    let length = try engine.editor.getBufferLength(url: url).uintValue
    return try engine.editor.getBufferData(url: url, offset: 0, length: length)
  }

  /// Writes `files` into the fill of `source`. `setSourceSet` takes the sizes as given, while
  /// `addImageFileURIToSourceSet` reads them from the file and replaces by width.
  /// `setSourceSet` resets the crop and the content fill mode of the block, as in the web plugin.
  private static func commit(_ files: ImageFiles, of source: ImageSource, engine: Engine) throws {
    try engine.block.setString(source.fill, property: imageFileURIProperty, value: files.image.absoluteString)
    if !source.sourceSet.isEmpty {
      let sourceSet = zip(source.sourceSet, files.sourceSet).map { original, url in
        Source(uri: url, width: original.width, height: original.height)
      }
      try engine.block.setSourceSet(source.fill, property: sourceSetProperty, sourceSet: sourceSet)
    }
    if try !engine.block.getString(source.fill, property: previewFileURIProperty).isEmpty {
      try engine.block.setString(source.fill, property: previewFileURIProperty, value: "")
    }
  }

  /// Turns the image in `data` upright. `@concurrent` keeps the redraw of a rotated photo off the main actor.
  @concurrent
  private static func decode(_ data: Data) async throws -> UIImage {
    guard let image = UIImage(data: data) else {
      throw BackgroundRemovalError.imageConversionFailed
    }
    return image.fixOrientation()
  }

  /// Writes `image` as PNG at its own size and at each of `sizes`. A size of zero gets the full-size file.
  /// `@concurrent` keeps the encoding off the main actor.
  @concurrent
  private static func savePNGs(of image: UIImage, sizes: [CGSize]) async throws -> ImageFiles {
    let imageSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let imageURL = try savePNG(image)
    let sourceSetURLs = try sizes.map { size in
      size == imageSize || size.width == 0 || size.height == 0 ? imageURL : try savePNG(image.resized(to: size))
    }
    return ImageFiles(image: imageURL, sourceSet: sourceSetURLs)
  }

  /// Deletes the files that `savePNGs(of:sizes:)` wrote, for a result that is not used.
  private static func delete(_ files: ImageFiles) {
    for url in Set([files.image] + files.sourceSet) {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private nonisolated static func savePNG(_ image: UIImage) throws -> URL {
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

// MARK: - Serial Queue

/// Gives out one turn at a time, in the order of the calls to `waitForTurn()`.
@MainActor
final class SerialQueue {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Swift.Error>
  }

  private var isBusy = false
  private var waiters: [Waiter] = []

  /// Returns when every earlier turn ended. Each turn that this returns must end with `endTurn()`. A call whose task is
  /// cancelled while it waits throws `CancellationError` at once and takes no turn.
  func waitForTurn() async throws {
    guard isBusy else {
      isBusy = true
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor in
        self.removeWaiter(id)
      }
    }
  }

  func endTurn() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

  private func removeWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

// MARK: - Source helpers

private extension Source {
  var pixelCount: Int {
    Int(width) * Int(height)
  }

  var size: CGSize {
    CGSize(width: Int(width), height: Int(height))
  }
}

// MARK: - UIImage helpers

extension UIImage {
  /// Returns the image with its pixel buffer in the visual orientation. A rotated image is redrawn at scale 1.
  func fixOrientation() -> UIImage {
    guard imageOrientation != .up else { return self }
    return resized(to: size)
  }

  /// Returns a copy of the image with exactly `size` pixels.
  func resized(to size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
