import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var visualIndex: Int? {
    if appState.navigator.isMultiSelectInProgress && item.selectionIndex >= 0 {
      return item.selectionIndex
    }
    return nil
  }

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Default(.showHexColorSwatch) private var showHexColorSwatch
  @AppStorage("localChatDragMode") private var chatMode = false
  @Environment(AppState.self) private var appState

  private var colorSwatchImage: NSImage? {
    guard showHexColorSwatch else { return nil }
    return ColorImage.from(item.title)
  }

  private var dragItems: [HistoryItem] {
    if item.isSelected && appState.navigator.isMultiSelectInProgress {
      return appState.navigator.selection.items.map(\.item)
    }
    return [item.item]
  }

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : colorSwatchImage,
      attributedTitle: item.attributedTitle,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      selectionIndex: visualIndex,
      selectionAppearance: selectionAppearance
    ) {
      Text(verbatim: item.title)
    }
    .padding(.leading, appState.navigator.isManualMultiSelect ? 24 : 0)
    .overlay(alignment: .leading) {
      if appState.navigator.isManualMultiSelect {
        Button {
          appState.navigator.addToSelection(item: item)
        } label: {
          Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(item.isSelected ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.leading, 7)
        .accessibilityLabel(NSLocalizedString(item.isSelected ? "Deselect item" : "Select item", comment: "Selection checkbox"))
      }
    }
    .overlay {
      HistoryNativeDragHandle(items: dragItems, onClick: handleClick,
                              excludedLeadingWidth: appState.navigator.isManualMultiSelect ? 24 : 0, chatMode: chatMode)
    }
    .help(ImageToolsModule.shared.enabled ? NSLocalizedString("Click to select · Enter to paste · use Image Tools for actions", comment: "Image tools selection") : "")
    .onAppear {
      item.ensureThumbnailImage()
    }
  }

  private func handleClick(_ flags: NSEvent.ModifierFlags) {
    if flags.contains(.shift), let anchor = appState.navigator.leadHistoryItem {
      appState.navigator.isManualMultiSelect = true
      appState.navigator.extendSelection(from: anchor, to: item, isRange: true)
    } else if appState.navigator.isManualMultiSelect || flags.contains(.command) {
      appState.navigator.addToSelection(item: item)
    } else if HistoryRowClickPolicy.selectsOnly(imageToolsEnabled: ImageToolsModule.shared.enabled, flags: flags) {
      appState.navigator.select(item: item)
    } else {
      Task { appState.history.select(item, flags: flags) }
    }
  }
}

struct HistoryRowClickPolicy {
  static func selectsOnly(imageToolsEnabled: Bool, flags: NSEvent.ModifierFlags) -> Bool {
    imageToolsEnabled && flags.intersection([.command, .option, .control, .shift]).isEmpty
  }
}

struct MultiDragBar: View {
  @AppStorage("localChatDragMode") private var chatMode = false
  @Environment(AppState.self) private var appState

  private var selected: [HistoryItem] { appState.navigator.selection.items.map(\.item) }
  private var chatText: String? {
    guard chatMode, let contents = HistoryDragPayload.contents(items: selected) else { return nil }
    return HistoryDragPayload.chatParts(contents: contents)?.text
  }

  var body: some View {
    HStack(spacing: 8) {
      Button(NSLocalizedString(appState.navigator.isManualMultiSelect ? "Done" : "Multi-select", comment: "Selection mode")) {
        let entering = !appState.navigator.isManualMultiSelect
        appState.navigator.select(item: nil)
        appState.navigator.isManualMultiSelect = entering
        if !entering { appState.navigator.highlightFirst() }
      }
      .buttonStyle(.borderless)

      if appState.navigator.isMultiSelectInProgress && !selected.isEmpty {
        if HistoryDragPayload.contents(items: selected) != nil {
          Button(NSLocalizedString(chatText != nil ? "Copy text" : "Copy combined", comment: "Copy selection")) {
            if let text = chatText {
              Clipboard.shared.copyTextForDrag(text)
              appState.popup.close()
            } else if Clipboard.shared.copyCombined(selected) {
              appState.popup.close()
            } else { NSSound.beep() }
          }
          .buttonStyle(.borderless)
          Label(HistoryDragLabels.count(selected.count), systemImage: "hand.draw")
            .overlay { HistoryNativeDragHandle(items: selected, chatMode: chatMode) }
            .help(NSLocalizedString("Drag selected text and images. Text-only selections are joined with newlines.", comment: "Drag help"))
        } else {
          Text(NSLocalizedString("This selection cannot be dragged", comment: "Unsupported selection"))
        }
      } else {
        Text(NSLocalizedString("Shift ↑/↓ select · Enter paste · ⇧Enter text", comment: "Keyboard selection help"))
      }
      Spacer(minLength: 0)
      Picker(NSLocalizedString("Drop mode", comment: "Drag compatibility mode"), selection: $chatMode) {
        Text(NSLocalizedString("Combined", comment: "Rich document mode")).tag(false)
        Text(NSLocalizedString("Chat attachments", comment: "Chat file mode")).tag(true)
      }
      .labelsHidden()
      .fixedSize()
    }
    .overlay(alignment: .bottomLeading) {
      if chatText != nil && appState.navigator.isMultiSelectInProgress {
        Text(NSLocalizedString("Drag images, then ⌘V for text", comment: "Chat drop instructions"))
          .font(.caption2)
          .offset(y: 14)
      }
    }
    .padding(.bottom, chatText != nil && appState.navigator.isMultiSelectInProgress ? 14 : 0)
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}

struct HistoryDragLabels {
  static func count(_ count: Int) -> String {
    if count == 1 { return NSLocalizedString("Drag 1 item", comment: "Drag one record") }
    return String(format: NSLocalizedString("Drag %ld items", comment: "Drag record count"), count)
  }
}
