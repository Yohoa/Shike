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

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
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
    guard Clipboard.shared.copyCombined(navigator.selection.items.map(\.item), plainText: plainText) else {
      NSSound.beep()
      return
    }
    navigator.isManualMultiSelect = false
    history.interruptPasteStack()
    popup.close()
    Clipboard.shared.paste()
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
    let nextUnselectedItem = history.visibleItems.nearest(to: leadItem) { !$0.isSelected }

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
            title: NSLocalizedString("Title", tableName: "GeneralSettings", comment: ""),
            toolbarIcon: NSImage.gearshape!
          ) {
            GeneralSettingsPane().settingsPaneWidth()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.storage,
            title: NSLocalizedString("Title", tableName: "StorageSettings", comment: ""),
            toolbarIcon: NSImage.externaldrive!
          ) {
            StorageSettingsPane().settingsPaneWidth()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.appearance,
            title: NSLocalizedString("Title", tableName: "AppearanceSettings", comment: ""),
            toolbarIcon: NSImage.paintpalette!
          ) {
            AppearanceSettingsPane().settingsPaneWidth()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.pins,
            title: NSLocalizedString("Title", tableName: "PinsSettings", comment: ""),
            toolbarIcon: NSImage.pincircle!
          ) {
            PinsSettingsPane()
              .environment(self)
              .modelContainer(Storage.shared.container)
              .settingsPaneWidth()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.ignore,
            title: NSLocalizedString("Title", tableName: "IgnoreSettings", comment: ""),
            toolbarIcon: NSImage.nosign!
          ) {
            IgnoreSettingsPane().settingsPaneWidth()
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.advanced,
            title: NSLocalizedString("Title", tableName: "AdvancedSettings", comment: ""),
            toolbarIcon: NSImage.gearshape2!
          ) {
            AdvancedSettingsPane().settingsPaneWidth()
          }
        ]
      )
    }
    settingsWindowController?.show()
    settingsWindowController?.window?.orderFrontRegardless()
  }

  func quit() {
    NSApp.terminate(self)
  }
}

private extension View {
  /// Eight toolbar tabs need about this much width; narrower panes pushed tabs into the "»" overflow.
  func settingsPaneWidth() -> some View { frame(minWidth: 820, alignment: .top) }
}
