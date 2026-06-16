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
    .package(url: "https://github.com/imgly/IMGLYUI-swift.git", exact: "1.77.0-rc.1"),
    .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", exact: "1.77.0"),
  ],
  targets: [
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
        .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
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
)
