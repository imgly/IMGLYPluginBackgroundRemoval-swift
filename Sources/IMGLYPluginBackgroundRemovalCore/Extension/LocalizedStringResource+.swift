import Foundation
@_spi(Internal) import IMGLYCore
@_spi(Internal) import IMGLYCoreUI

extension LocalizationTable {
  static let imglyPluginBackgroundRemoval = LocalizationTable(
    table: "IMGLYPluginBackgroundRemoval",
    bundle: .module,
  )
}

extension LocalizedStringResource {
  static let backgroundRemovalDockButton: LocalizedStringResource = .imgly
    .localized("ly_img_plugin_background_removal_dock_button", table: .imglyPluginBackgroundRemoval)
}
