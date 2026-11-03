import AppKit
import Defaults
import Foundation
import Settings
import SwiftUI

@Observable
class AppState: Sendable {
  static let shared = AppState(history: History.shared, footer: Footer())

  let multiSelectionEnabled = true

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController

  var isEditingItem: Bool = false
  var suppressPopupAutoClose: Bool {
    return navigator.isDragAndDropInProgress || isEditingItem
  }

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.firstUnpinnedItem?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: SettingsWindowController?

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
    popup = Popup()
    navigator = NavigationManager(history: history, footer: footer)
    preview = SlideoutController(
      onContentResize: { contentWidth in
        Defaults[.windowSize].width = contentWidth
      },
      onSlideoutResize: { previewWidth in
        Defaults[.previewWidth] = previewWidth
      })
    preview.contentWidth = Defaults[.windowSize].width
    preview.slideoutWidth = Defaults[.previewWidth]
  }

  @MainActor
  func select(flags modifierFlags: NSEvent.ModifierFlags) {
    if !navigator.selection.isEmpty {
      if navigator.isMultiSelectInProgress {
        navigator.isManualMultiSelect = false
        if Clipboard.shared.copyCombined(navigator.selection.items.map(\.item)) {
          popup.close()
          let action = HistoryItemAction(modifierFlags)
          if action == .paste || action == .pasteWithoutFormatting
            || (action == .unknown && Defaults[.pasteByDefault]) { Clipboard.shared.paste() }
        } else {
          NSSound.beep()
        }
      } else {
        history.select(navigator.selection.first, flags: modifierFlags)
      }
    } else if let item = footer.selectedItem {
      // TODO: Use item.suppressConfirmation, but it's not updated!
      if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
        item.showConfirmation = true
      } else {
        item.action()
      }
    } else {
      Clipboard.shared.copyInMaccy(history.searchQuery)
      history.searchQuery = ""
    }
  }

  @MainActor
  func pasteSelectionFromKeyboard(plainText: Bool) {
    guard !navigator.selection.isEmpty else {
      select(flags: plainText ? .shift : [])
      return
    }
    guard copySelectedItems(plainText: plainText) else {
      NSSound.beep()
      return
    }
    navigator.isManualMultiSelect = false
    history.interruptPasteStack()
    popup.close()
    Clipboard.shared.paste()
  }

  /// One item goes back on the clipboard with its original data, so the history just moves it to the top
  /// instead of recording a converted duplicate; several items are combined into one new entry.
  @MainActor
  private func copySelectedItems(plainText: Bool) -> Bool {
    let items = navigator.selection.items.map(\.item)
    guard items.count == 1, let item = items.first else {
      return Clipboard.shared.copyCombined(items, plainText: plainText)
    }
    Clipboard.shared.copy(item, removeFormatting: plainText, notify: false)
    return true
  }

  /// ⌘C: put the selected item(s) on the clipboard without pasting, then fade the popup out
  /// (or keep it open, per Settings → General).
  @MainActor
  @discardableResult
  func copySelection() -> Bool {
    guard !navigator.selection.isEmpty else { return false }
    guard copySelectedItems(plainText: false) else {
      NSSound.beep()
      return true
    }
    ToastHUD.show(NSLocalizedString("Copied", comment: "Copy toast"))
    if !Defaults[.keepPopupOpenAfterCopy] { popup.fadeOut(over: 0.5) }
    return true
  }

  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.togglePin(item)
      }
    }
  }

  @MainActor
  func removePasteStack() {
    history.interruptPasteStack()
    navigator.highlightFirst()
  }

  @MainActor
  func deleteSelection() {
    guard let leadItem = navigator.leadHistoryItem else { return }
    let nextUnselectedItem = history.nearestVisible(to: leadItem) { !$0.isSelected }

    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.delete(item)
      }
      navigator.select(item: nextUnselectedItem)
    }
  }

  func openAbout() {
    about.openAbout(nil)
  }

  @MainActor
  func openPreferences() { // swiftlint:disable:this function_body_length
    if settingsWindowController == nil {
      let generalTitle = NSLocalizedString("Title", tableName: "GeneralSettings", comment: "")
      let storageTitle = NSLocalizedString("Title", tableName: "StorageSettings", comment: "")
      let appearanceTitle = NSLocalizedString("Title", tableName: "AppearanceSettings", comment: "")
      let ignoreTitle = NSLocalizedString("Title", tableName: "IgnoreSettings", comment: "")
      let advancedTitle = NSLocalizedString("Title", tableName: "AdvancedSettings", comment: "")
      let toolbarTitles = [generalTitle, storageTitle, appearanceTitle, ignoreTitle, advancedTitle]
      let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
      let titleWidth = toolbarTitles.reduce(CGFloat.zero) {
        $0 + ($1 as NSString).size(withAttributes: titleAttributes).width
      }
      let toolbarItemSpacing: CGFloat = 24
      let toolbarEdgeSpacing: CGFloat = 40
      let toolbarWidth = titleWidth + CGFloat(toolbarTitles.count) * toolbarItemSpacing + toolbarEdgeSpacing
      let minimumWidth = max(500, ceil(toolbarWidth))
      settingsWindowController = SettingsWindowController(
        panes: [
          Settings.Pane(identifier: Settings.PaneIdentifier(rawValue: "notch"),
                        title: NSLocalizedString("Notch", comment: "Notch settings"),
                        toolbarIcon: NSImage(systemSymbolName: "capsule", accessibilityDescription: nil)!) { NotchSettings().settingsPaneWidth() },
          Settings.Pane(
            identifier: Settings.PaneIdentifier(rawValue: "imageTools"),
            title: NSLocalizedString("Image Tools", comment: "Image tools settings"),
            toolbarIcon: NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)!
          ) { ImageToolsSettings().settingsPaneWidth() },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.general,
            title: generalTitle,
            toolbarIcon: NSImage.gearshape!
          ) {
            GeneralSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.storage,
            title: storageTitle,
            toolbarIcon: NSImage.externaldrive!
          ) {
            StorageSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.appearance,
            title: appearanceTitle,
            toolbarIcon: NSImage.paintpalette!
          ) {
            AppearanceSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.ignore,
            title: ignoreTitle,
            toolbarIcon: NSImage.nosign!
          ) {
            IgnoreSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.advanced,
            title: advancedTitle,
            toolbarIcon: NSImage.gearshape2!
          ) {
            AdvancedSettingsPane()
              .frame(minWidth: minimumWidth)
          }
        ]
      )
    }
    settingsWindowController?.show()
    settingsWindowController?.window?.orderFrontRegardless()
  }

  func quit() {
    TerminationGuard.shared.quit()
  }
}

private extension View {
  /// Eight toolbar tabs need about this much width; narrower panes pushed tabs into the "»" overflow.
  func settingsPaneWidth() -> some View { frame(minWidth: 820, alignment: .top) }
}
