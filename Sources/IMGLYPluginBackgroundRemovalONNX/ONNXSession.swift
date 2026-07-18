import Foundation
import IMGLYPluginBackgroundRemovalCore

// SPM ships the ORT Obj-C bindings as `OnnxRuntimeBindings`; the
// `onnxruntime-objc` CocoaPod ships them as `onnxruntime_objc`. Both
// re-export the same `ORTEnv` / `ORTSession` / `ORTValue` / `ORTRunOptions`
// classes.
#if canImport(OnnxRuntimeBindings)
  import OnnxRuntimeBindings
#elseif canImport(onnxruntime_objc)
  import onnxruntime_objc
#endif

/// Lazy, actor-isolated wrapper around an `ORTSession`.
///
/// The session is built on first call to ``run(input:)`` and reused for
/// all subsequent inferences.
actor ONNXSession {
  // `ORTEnv` is shared across sessions per ORT's recommendation. The Obj-C
  // class isn't marked `Sendable`, so opt out of the Swift 6 check.
  // Force-try is safe: the only failure path is an invalid logging level.
  // swiftlint:disable:next force_try
  private nonisolated(unsafe) static let env: ORTEnv = try! ORTEnv(loggingLevel: .warning)

  private let modelURL: URL
  private let model: IMGLYBackgroundRemovalConfiguration.Model
  private var session: ORTSession?

  init(modelURL: URL, model: IMGLYBackgroundRemovalConfiguration.Model) {
    self.modelURL = modelURL
    self.model = model
  }

  /// Builds the ORT session if it doesn't exist yet.
  func prewarm() throws {
    _ = try getSession()
  }

  func run(input: [Float]) throws -> [Float] {
    let session = try getSession()
    let modelInputSize = Preprocessing.modelInputSize

    let inputData = NSMutableData(bytes: input, length: input.count * MemoryLayout<Float>.size)
    let shape: [NSNumber] = [1, 3, NSNumber(value: modelInputSize), NSNumber(value: modelInputSize)]
    let inputValue = try ORTValue(
      tensorData: inputData,
      elementType: .float,
      shape: shape,
    )

    // Shrink the CPU arena after each run. The session-level capability
    // set in `getSession()` only enables this; it must be requested per
    // `Run()` via `ORTRunOptions` to actually fire.
    let runOptions = try ORTRunOptions()
    try runOptions.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")

    let results = try session.run(
      withInputs: ["input": inputValue],
      outputNames: Set(["output"]),
      runOptions: runOptions,
    )

    guard let outputValue = results["output"] else {
      throw BackgroundRemovalError.inferenceFailed("ORT session returned no output tensor")
    }

    let outputData = try outputValue.tensorData() as Data
    let floatCount = outputData.count / MemoryLayout<Float>.size
    var floats = [Float](repeating: 0, count: floatCount)
    floats.withUnsafeMutableBytes { dstRaw in
      outputData.withUnsafeBytes { srcRaw in
        guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else { return }
        dst.copyMemory(from: src, byteCount: outputData.count)
      }
    }
    return floats
  }

  // MARK: - Private

  private func getSession() throws -> ORTSession {
    if let session {
      return session
    }

    let options = try ORTSessionOptions()

    // Route FP16 to the Neural Engine; route FP32 to the GPU. The Neural
    // Engine is FP16-only and would silently downcast FP32 weights.
    let computeUnits = switch model {
    case .fp16:
      "CPUAndNeuralEngine"
    case .fp32:
      "CPUAndGPU"
    }

    try options.appendCoreMLExecutionProvider(withOptionsV2: [
      "ModelFormat": "MLProgram",
      "MLComputeUnits": computeUnits,
      "RequireStaticInputShapes": "1",
      "AllowLowPrecisionAccumulationOnGPU": "0",
    ])
    // `.all` enables NCHWc layout conversion which spikes RAM during build.
    try options.setGraphOptimizationLevel(.extended)
    // ORT's weight-prepacking is unused when CoreML delegates the model.
    try options.addConfigEntry(withKey: "session.disable_prepacking", value: "1")
    try options.addConfigEntry(withKey: "session.use_device_allocator_for_initializers", value: "1")
    // Enables the per-run shrinkage requested in `run(input:)`.
    try options.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")

    let built = try ORTSession(env: Self.env, modelPath: modelURL.path, sessionOptions: options)
    session = built
    return built
  }
}
