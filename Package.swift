// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "IMGLYPluginBackgroundRemoval",
  defaultLocalization: "en",
  platforms: [.iOS(.v16)],
  products: [
    .library(name: "IMGLYPluginBackgroundRemoval", targets: ["IMGLYPluginBackgroundRemoval"]),
  ],
  dependencies: [
    .package(url: "https://github.com/imgly/IMGLYUI-swift.git", exact: "1.76.0"),
  ],
  targets: [
    .target(
      name: "IMGLYPluginBackgroundRemoval",
      dependencies: [.product(name: "IMGLYUI", package: "IMGLYUI-swift")],
    ),
  ],
)
