// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "IMGLYPluginBackgroundRemoval",
  defaultLocalization: "en",
  platforms: [.iOS(.v16)],
  products: [
    .library(
      name: "IMGLYPluginBackgroundRemovalCore",
      targets: ["IMGLYPluginBackgroundRemovalCore"],
    ),
    .library(
      name: "IMGLYPluginBackgroundRemovalVision",
      targets: ["IMGLYPluginBackgroundRemovalVision"],
    ),
    .library(
      name: "IMGLYPluginBackgroundRemovalONNX",
      targets: ["IMGLYPluginBackgroundRemovalONNX"],
    ),
    // Umbrella: importing `IMGLYPluginBackgroundRemoval` re-exports Core,
    // Vision, and ONNX, and unlocks the zero-arg `BackgroundRemovalPlugin()`
    // convenience init. The umbrella is a real target (not just a
    // multi-target library aggregate) so the module name resolves at
    // `import` time.
    .library(
      name: "IMGLYPluginBackgroundRemoval",
      targets: ["IMGLYPluginBackgroundRemoval"],
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/imgly/IMGLYUI-swift.git", exact: "1.77.1"),
  ],
  targets: [
    .binaryTarget(
      name: "onnxruntime",
      url: "https://cdn.img.ly/packages/imgly/onnxruntime/1.24.2/onnxruntime.xcframework.zip",
      checksum: "03f4cb6719fa308b4e521cbcf6ba4ae1bc7d52bda4f46d1cf707b0ef2a0aac9e",
    ),
    .target(
      name: "OnnxRuntimeBindings",
      dependencies: ["onnxruntime"],
      path: "Sources/OnnxRuntimeBindings",
      cxxSettings: [.define("SPM_BUILD")],
    ),
    .target(
      name: "IMGLYPluginBackgroundRemovalCore",
      dependencies: [
        .product(name: "IMGLYUI", package: "IMGLYUI-swift"),
      ],
      // Explicit so SPM generates `Bundle.module`. Auto-detection of root-level
      // `.xcstrings` without an `.lproj` parent isn't reliable across SPM
      // versions, and `LocalizedStringResource+.swift` references `.module`.
      resources: [
        .process("IMGLYPluginBackgroundRemoval.xcstrings"),
      ],
    ),
    .target(
      name: "IMGLYPluginBackgroundRemovalVision",
      dependencies: [
        .target(name: "IMGLYPluginBackgroundRemovalCore"),
      ],
    ),
    .target(
      name: "IMGLYPluginBackgroundRemovalONNX",
      dependencies: [
        .target(name: "IMGLYPluginBackgroundRemovalCore"),
        .target(name: "OnnxRuntimeBindings"),
      ],
    ),
    .target(
      name: "IMGLYPluginBackgroundRemoval",
      dependencies: [
        .target(name: "IMGLYPluginBackgroundRemovalCore"),
        .target(name: "IMGLYPluginBackgroundRemovalVision"),
        .target(name: "IMGLYPluginBackgroundRemovalONNX"),
      ],
    ),
  ],
  cxxLanguageStandard: .cxx17,
)
