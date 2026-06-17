import Foundation
import IMGLYPluginBackgroundRemovalCore

/// Resolves a model base URL and variant to a local `.onnx` file path.
///
/// `file://` base URLs are looked up directly; `http(s)://` base URLs are
/// stream-downloaded and cached on disk.
enum ModelDownloader {
  /// Returns the on-disk path to the requested model, downloading it if
  /// necessary.
  static func resolve(
    modelBaseURL: URL,
    model: IMGLYBackgroundRemovalConfiguration.Model,
  ) async throws -> URL {
    let filename = model.rawValue

    if modelBaseURL.isFileURL {
      let modelURL = modelBaseURL.appendingPathComponent(filename)
      guard FileManager.default.fileExists(atPath: modelURL.path) else {
        throw BackgroundRemovalError.modelNotFound("Bundled model not found at \(modelURL.path)")
      }
      return modelURL
    }

    return try await downloadFromCDN(
      remoteURL: modelBaseURL.appendingPathComponent(filename),
      filename: filename,
    )
  }

  // MARK: - CDN download

  private static func downloadFromCDN(
    remoteURL: URL,
    filename: String,
  ) async throws -> URL {
    let cacheRoot = try defaultCacheDirectory()
    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

    let cachedModel = cacheRoot.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: cachedModel.path) {
      return cachedModel
    }

    // Unique scratch path so two concurrent downloads of the same variant
    // can't corrupt each other. Final move-into-place is atomic.
    let scratchURL = cacheRoot.appendingPathComponent("\(filename).\(UUID().uuidString).partial")
    do {
      try await streamDownload(remoteURL: remoteURL, into: scratchURL)
      try FileManager.default.moveItem(at: scratchURL, to: cachedModel)
    } catch {
      try? FileManager.default.removeItem(at: scratchURL)
      throw error
    }

    return cachedModel
  }

  private static func streamDownload(remoteURL: URL, into output: URL) async throws {
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await URLSession.shared.bytes(from: remoteURL)
    } catch {
      throw BackgroundRemovalError.modelDownloadFailed(error.localizedDescription)
    }

    // `bytes(from:)` does not throw on non-2xx responses — without this check
    // an HTML error page would be cached as if it were the model file.
    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      throw BackgroundRemovalError.modelDownloadFailed("HTTP \(http.statusCode)")
    }

    guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
      throw BackgroundRemovalError.modelDownloadFailed("Could not create scratch file at \(output.path)")
    }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }

    var buffer = Data(capacity: 256 * 1024)
    do {
      for try await byte in bytes {
        try Task.checkCancellation()
        buffer.append(byte)
        if buffer.count >= 256 * 1024 {
          try handle.write(contentsOf: buffer)
          buffer.removeAll(keepingCapacity: true)
        }
      }
      if !buffer.isEmpty {
        try handle.write(contentsOf: buffer)
      }
    } catch let error as CancellationError {
      throw error
    } catch {
      throw BackgroundRemovalError.modelDownloadFailed(error.localizedDescription)
    }
  }

  // MARK: - Cache path

  private static func defaultCacheDirectory() throws -> URL {
    try FileManager.default
      .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("ly.img.plugin.backgroundRemoval/onnx", isDirectory: true)
  }
}
