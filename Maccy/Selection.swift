import AppKit

struct Selection<Item: Equatable> {
  var items: [Item]

  init(items: [Item] = []) {
    self.items = items
  }

  var isEmpty: Bool {
    return items.isEmpty
  }

  var count: Int {
    return items.count
  }

  var first: Item? {
    return items.first
  }

  func first(where condition: (Item) -> Bool) -> Item? {
    return items.first(where: condition)
  }

  func forEach(_ body: (Int, Item) throws -> Void) rethrows {
    try items.enumerated().forEach(body)
  }

  mutating func remove(_ item: Item) {
    items.removeAll { $0 == item }
  }

  mutating func add(_ item: Item) {
    items.append(item)
  }
}

// A single plain-text representation makes a multi-record drop work in editors
// that only accept one pasteboard item. Never substitute truncated titles/OCR.
@MainActor
struct HistoryDragPayload {
  static func text(items: [HistoryItem]) -> String? {
    guard !items.isEmpty else { return nil }
    var values: [String] = []
    for item in items {
      guard item.imageData == nil, item.fileURLs.isEmpty else { return nil }
      if let text = item.text {
        values.append(text)
      } else if let text = item.rtf?.string ?? item.html?.string {
        values.append(text)
      } else {
        return nil
      }
    }
    return values.joined(separator: "\n")
  }

  static func provider(items: [HistoryItem]) -> NSItemProvider? {
    guard let contents = contents(items: items) else { return nil }
    return provider(contents: contents)
  }
}

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct HistoryDragContent {
  var text: String?
  var imageData: Data?
  var typeIdentifier: String?
  var fileExtension: String?
  var rtfData: Data?
  var htmlData: Data?
}

extension HistoryDragPayload {
  static func contents(items: [HistoryItem]) -> [HistoryDragContent]? {
    guard !items.isEmpty else { return nil }
    var result: [HistoryDragContent] = []
    for item in items {
      if let data = item.imageData {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else { return nil }
        if let text = item.text, !text.isEmpty { result.append(HistoryDragContent(text: text)) }
        result.append(HistoryDragContent(imageData: data, typeIdentifier: type,
                                         fileExtension: UTType(type)?.preferredFilenameExtension ?? "img"))
      } else {
        guard item.fileURLs.isEmpty, let value = item.text ?? item.rtf?.string ?? item.html?.string else { return nil }
        result.append(HistoryDragContent(text: value, rtfData: item.rtfData, htmlData: item.htmlData))
      }
    }
    return result
  }

  static func provider(contents: [HistoryDragContent]) -> NSItemProvider? {
    guard !contents.isEmpty else { return nil }
    if contents.allSatisfy({ $0.text != nil }) {
      return NSItemProvider(object: contents.compactMap(\.text).joined(separator: "\n") as NSString)
    }
    if contents.count == 1, let image = contents.first,
       let data = image.imageData, let type = image.typeIdentifier {
      let provider = NSItemProvider(item: data as NSData, typeIdentifier: type)
      provider.suggestedName = "Shike.\(image.fileExtension ?? "img")"
      return provider
    }
    guard let item = combinedItem(contents: contents), let data = item.data(forType: .rtfd) else { return nil }
    let provider = NSItemProvider(item: data as NSData, typeIdentifier: NSPasteboard.PasteboardType.rtfd.rawValue)
    if let html = item.data(forType: .html) {
      provider.registerDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.html.rawValue, visibility: .all) {
        completion in completion(html, nil); return nil
      }
    }
    if let text = item.string(forType: .string) { provider.registerObject(text as NSString, visibility: .all) }
    return provider
  }

  static func clipboardItem(items: [HistoryItem], plainText: Bool) -> NSPasteboardItem? {
    if !plainText {
      guard let contents = contents(items: items) else { return nil }
      return combinedItem(contents: contents)
    }
    let values = items.compactMap { item -> String? in
      if let text = item.text, !text.isEmpty { return text }
      return item.rtf?.string ?? item.html?.string
    }
    guard values.contains(where: { !$0.isEmpty }) else { return nil }
    let item = NSPasteboardItem()
    item.setString(values.joined(separator: "\n"), forType: .string)
    return item
  }

  static func combinedItem(contents: [HistoryDragContent]) -> NSPasteboardItem? {
    guard !contents.isEmpty else { return nil }
    let document = NSMutableAttributedString(string: "")
    for (index, content) in contents.enumerated() {
      if index > 0 { document.append(NSAttributedString(string: "\n")) }
      if let text = content.text {
        let rich = content.rtfData.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
          ?? content.htmlData.flatMap { NSAttributedString(html: $0, documentAttributes: nil) }
        document.append(rich ?? NSAttributedString(string: text))
      } else if let data = content.imageData {
        let attachment = NSTextAttachment()
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "Shike-\(index + 1).\(content.fileExtension ?? "img")"
        attachment.fileWrapper = wrapper
        document.append(NSAttributedString(attachment: attachment))
      }
    }
    guard let data = document.rtfd(from: NSRange(location: 0, length: document.length), documentAttributes: [:]) else {
      return nil
    }
    let item = NSPasteboardItem()
    item.setData(data, forType: .rtfd)
    let body = contents.map { content -> String in
      if let text = content.text {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
          .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
          .replacingOccurrences(of: "\"", with: "&quot;")
        return "<div style=\"white-space:pre-wrap\">" + escaped + "</div>"
      }
      if let data = content.imageData, let type = content.typeIdentifier {
        let mime = UTType(type)?.preferredMIMEType ?? "application/octet-stream"
        return "<div><img src=\"data:" + mime + ";base64," + data.base64EncodedString() + "\"></div>"
      }
      return ""
    }.joined()
    item.setString("<html><head><meta charset=\"utf-8\"></head><body>" + body + "</body></html>", forType: .html)
    let text = contents.compactMap(\.text).joined(separator: "\n")
    if !text.isEmpty { item.setString(text, forType: .string) }
    return item
  }

  static func isMixed(_ contents: [HistoryDragContent]) -> Bool {
    contents.contains(where: { $0.text != nil }) && contents.contains(where: { $0.imageData != nil })
  }

  static func chatParts(contents: [HistoryDragContent]) -> (text: String, images: [HistoryDragContent])? {
    guard isMixed(contents) else { return nil }
    return (contents.compactMap(\.text).joined(separator: "\n"), contents.filter { $0.imageData != nil })
  }

  static func pasteboardItems(contents: [HistoryDragContent], directory: URL) throws -> [NSPasteboardItem] {
    if contents.allSatisfy({ $0.text != nil }) {
      let item = NSPasteboardItem()
      item.setString(contents.compactMap(\.text).joined(separator: "\n"), forType: .string)
      return contents.isEmpty ? [] : [item]
    }
    // A mixed selection is one document, not unrelated alternatives that a
    // receiver may filter down to just its image items.
    if contents.contains(where: { $0.text != nil }), contents.contains(where: { $0.imageData != nil }) {
      guard let item = combinedItem(contents: contents) else { throw CocoaError(.coderInvalidValue) }
      return [item]
    }
    return try contents.enumerated().map { index, content in
      let item = NSPasteboardItem()
      if let text = content.text {
        item.setString(text, forType: .string)
      } else if let data = content.imageData, let type = content.typeIdentifier {
        let url = directory.appendingPathComponent("Shike-\(index + 1).\(content.fileExtension ?? "img")")
        try data.write(to: url, options: .atomic)
        item.setData(data, forType: NSPasteboard.PasteboardType(type))
        item.setString(url.absoluteString, forType: .fileURL)
      }
      return item
    }
  }
}

// Native AppKit dragging is needed for multiple image/file pasteboard items;
// SwiftUI onDrag only returns one NSItemProvider.
struct HistoryNativeDragHandle: NSViewRepresentable {
  var items: [HistoryItem]
  var onClick: ((NSEvent.ModifierFlags) -> Void)?
  var excludedLeadingWidth: CGFloat = 0
  var chatMode: Bool = false
  /// Force Touch (deep press) on the row; receives the row's view as a popover anchor.
  var onForceClick: ((NSView) -> Void)?
  /// Replaces the default (image tools) right-click menu when set.
  var contextMenu: ((NSView) -> NSMenu?)?
  /// IDs this drag carries when dropped back on the same list (in-app reordering).
  var reorderIDs: [UUID] = []

  func makeNSView(context: Context) -> HistoryNativeDragView { HistoryNativeDragView() }
  func updateNSView(_ view: HistoryNativeDragView, context: Context) {
    view.snapshot = { HistoryDragPayload.contents(items: items) }
    view.fileSnapshot = { items.allSatisfy { !$0.fileURLs.isEmpty } ? items.flatMap(\.fileURLs) : [] }
    view.onClick = onClick
    view.excludedLeadingWidth = excludedLeadingWidth
    view.chatMode = chatMode
    view.imageToolsMenu = { ImageToolsModule.shared.menu(items: items) }
    view.onForceClick = onForceClick
    view.contextMenu = contextMenu
    view.reorderIDs = reorderIDs
  }
}

final class HistoryNativeDragView: NSView, NSDraggingSource {
  var snapshot: (() -> [HistoryDragContent]?)?
  var fileSnapshot: (() -> [URL])?
  var onClick: ((NSEvent.ModifierFlags) -> Void)?
  var excludedLeadingWidth: CGFloat = 0
  var chatMode = false
  var imageToolsMenu: (() -> NSMenu?)?
  var contextMenu: ((NSView) -> NSMenu?)?
  var onForceClick: ((NSView) -> Void)?
  var reorderIDs: [UUID] = []
  override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(self) ?? imageToolsMenu?() }
  private var startPoint: NSPoint?
  private var forceFired = false
  // A trackpad press often drifts a few points. A drag that ends quickly near where it began is
  // treated as the click the user meant, otherwise the click silently became a no-op drag.
  private var pressStart: (screen: NSPoint, time: TimeInterval, flags: NSEvent.ModifierFlags)?
  private static let dragThreshold: CGFloat = 8
  private var exportDirectory: URL?
  override var isOpaque: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if convert(point, from: superview).x < excludedLeadingWidth { return nil }
    return super.hitTest(point)
  }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    startPoint = event.locationInWindow
    pressStart = (NSEvent.mouseLocation, event.timestamp, event.modifierFlags)
    forceFired = false
  }
  override func pressureChange(with event: NSEvent) {
    // Stage 2 is the deep "force click"; it replaces the normal click for this press.
    guard event.stage >= 2, !forceFired, let onForceClick else { return }
    forceFired = true
    startPoint = nil
    onForceClick(self)
  }
  override func mouseUp(with event: NSEvent) {
    guard startPoint != nil else { return }
    startPoint = nil
    onClick?(event.modifierFlags)
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start = startPoint,
          hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= Self.dragThreshold else { return }
    startPoint = nil
    let files = fileSnapshot?() ?? []
    if !files.isEmpty {
      let items = files.map { url in
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: NSSize(width: 40, height: 40)),
                              contents: Self.dragIcon("doc.fill"))
        return item
      }
      beginDraggingSession(with: items, event: event, source: self)
      return
    }
    guard let contents = snapshot?() else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShikeDrag-\(UUID())")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let chat = chatMode ? HistoryDragPayload.chatParts(contents: contents) : nil
      let writers = try HistoryDragPayload.pasteboardItems(contents: chat?.images ?? contents, directory: directory)
      guard !writers.isEmpty else { try? FileManager.default.removeItem(at: directory); return }
      let items = writers.enumerated().map { index, writer in
        let item = NSDraggingItem(pasteboardWriter: writer)
        let icon = Self.dragIcon(contents.contains(where: { $0.imageData != nil }) ? "photo.fill" : "doc.text.fill")
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 20 + CGFloat(index * 4), y: point.y - 20 + CGFloat(index * 4), width: 40, height: 40),
                              contents: icon)
        return item
      }
      if let text = chat?.text { Clipboard.shared.copyTextForDrag(text) }
      exportDirectory = directory
      let session = beginDraggingSession(with: items, event: event, source: self)
      session.draggingFormation = .pile
    } catch {
      try? FileManager.default.removeItem(at: directory)
      NSSound.beep()
    }
  }

  /// White symbol with a soft dark halo, so the drag image stays visible over the black notch and light windows alike.
  static func dragIcon(_ symbol: String) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium).applying(.init(paletteColors: [.white]))
    guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
    let size = NSSize(width: 40, height: 40)
    return NSImage(size: size, flipped: false) { rect in
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
      shadow.shadowBlurRadius = 4
      shadow.shadowOffset = NSSize(width: 0, height: -1)
      shadow.set()
      let g = glyph.size
      glyph.draw(in: NSRect(x: rect.midX - g.width / 2, y: rect.midY - g.height / 2, width: g.width, height: g.height))
      return true
    }
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .withinApplication && !reorderIDs.isEmpty ? [.copy, .move] : .copy
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    if let press = pressStart, onClick != nil, !forceFired,
       hypot(screenPoint.x - press.screen.x, screenPoint.y - press.screen.y) < 16,
       ProcessInfo.processInfo.systemUptime - press.time < 0.6,
       operation.isEmpty || window?.frame.contains(screenPoint) == true {
      pressStart = nil
      onClick?(press.flags)
    }
    pressStart = nil
    guard let directory = exportDirectory else { return }
    exportDirectory = nil
    // Give receivers time to finish copying before removing temporary exports.
    DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
