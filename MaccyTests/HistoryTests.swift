import XCTest
import Defaults
@testable import Maccy

@MainActor
class HistoryTests: XCTestCase {
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPinTo = Defaults[.pinTo]
  let history = History.shared

  override func setUp() {
    super.setUp()
    history.clearAll()
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.pinTo] = .bottom
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.pinTo] = savedPinTo
  }

  func testDragJoinsFullTextInSelectionOrder() {
    let longText = String(repeating: "正文🙂", count: 500)
    let first = historyItem(longText)
    let second = historyItem("second\nline")
    XCTAssertEqual(HistoryDragPayload.text(items: [second, first]), "second\nline\n" + longText)
    XCTAssertTrue(HistoryDragPayload.provider(items: [first, second])!.canLoadObject(ofClass: NSString.self))
  }

  func testDragProviderLoadsMergedText() async throws {
    let provider = try XCTUnwrap(HistoryDragPayload.provider(items: [historyItem("第一条🙂"), historyItem("second")]))
    let transferred: String = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadObject(ofClass: NSString.self) { value, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let text = value as? String {
          continuation.resume(returning: text)
        } else {
          continuation.resume(throwing: CocoaError(.coderInvalidValue))
        }
      }
    }
    XCTAssertEqual(transferred, "第一条🙂\nsecond")
  }

  func testDragRejectsEmptyAndImageSelections() {
    XCTAssertNil(HistoryDragPayload.text(items: []))
    let image = HistoryItem(contents: [HistoryItemContent(type: "public.png", value: Data([1, 2, 3]))])
    XCTAssertNil(HistoryDragPayload.provider(items: [historyItem("text"), image]))
  }

  private func dragTestImage(_ color: NSColor) throws -> (HistoryItem, Data) {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 23, pixelsHigh: 17,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<23 {
      for y in 0..<17 { bitmap.setColor(color, atX: x, y: y) }
    }
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let item = HistoryItem(contents: [HistoryItemContent(type: "public.png", value: data)])
    return (item, data)
  }

  func testSingleImageProviderPreservesOriginalData() async throws {
    let (image, data) = try dragTestImage(.red)
    let provider = try XCTUnwrap(HistoryDragPayload.provider(items: [image]))
    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.png"))
    let received: Data = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: "public.png") { data, error in
        if let error { continuation.resume(throwing: error) }
        else if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: CocoaError(.coderInvalidValue)) }
      }
    }
    XCTAssertEqual(received, data)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: received))
    XCTAssertEqual(bitmap.pixelsWide, 23)
    XCTAssertEqual(bitmap.pixelsHigh, 17)
  }

  func testMultipleImagesExportDistinctOriginalFiles() throws {
    let (red, redData) = try dragTestImage(.red)
    let (blue, blueData) = try dragTestImage(.blue)
    let contents = try XCTUnwrap(HistoryDragPayload.contents(items: [red, blue]))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let items = try HistoryDragPayload.pasteboardItems(contents: contents, directory: directory)
    XCTAssertEqual(items.count, 2)
    for (index, expected) in [redData, blueData].enumerated() {
      XCTAssertEqual(items[index].data(forType: .png), expected)
      let url = try XCTUnwrap(URL(string: try XCTUnwrap(items[index].string(forType: .fileURL))))
      XCTAssertEqual(try Data(contentsOf: url), expected)
    }
    XCTAssertNotEqual(items[0].string(forType: .fileURL), items[1].string(forType: .fileURL))
  }

  func testMixedNativeDragPreservesOrderAndText() throws {
    let (image, data) = try dragTestImage(.green)
    let contents = try XCTUnwrap(HistoryDragPayload.contents(items: [historyItem("before"), image, historyItem("after")]))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let items = try HistoryDragPayload.pasteboardItems(contents: contents, directory: directory)
    XCTAssertEqual(items.count, 1)
    let item = try XCTUnwrap(items.first)
    XCTAssertEqual(item.string(forType: .string), "before\nafter")
    let document = try XCTUnwrap(NSAttributedString(rtfd: try XCTUnwrap(item.data(forType: .rtfd)), documentAttributes: nil))
    XCTAssertEqual(document.string, "before\n\u{fffc}\nafter")
    let attachment = try XCTUnwrap(document.attribute(.attachment, at: 7, effectiveRange: nil) as? NSTextAttachment)
    XCTAssertEqual(attachment.fileWrapper?.regularFileContents, data)
  }

  func testNativeTextReceiverReadsTextAndAttachmentTogether() throws {
    let (image, _) = try dragTestImage(.red)
    let contents = try XCTUnwrap(HistoryDragPayload.contents(items: [historyItem("before"), image, historyItem("after")]))
    let item = try XCTUnwrap(HistoryDragPayload.combinedItem(contents: contents))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    XCTAssertTrue(pasteboard.writeObjects([item]))
    let receiver = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    receiver.isRichText = true
    receiver.importsGraphics = true
    XCTAssertTrue(receiver.readSelection(from: pasteboard))
    XCTAssertEqual(receiver.string, "before\n\u{fffc}\nafter")
    XCTAssertNotNil(receiver.textStorage?.attribute(.attachment, at: 7, effectiveRange: nil))
  }

  func testCombinedHTMLAndPlainTextFallback() throws {
    let (image, data) = try dragTestImage(.blue)
    let contents = try XCTUnwrap(HistoryDragPayload.contents(items: [historyItem("<&\"\nfirst"), image, historyItem("last")]))
    let item = try XCTUnwrap(HistoryDragPayload.combinedItem(contents: contents))
    let html = try XCTUnwrap(item.string(forType: .html))
    XCTAssertTrue(html.contains("&lt;&amp;&quot;"))
    XCTAssertTrue(html.contains("data:image/png;base64," + data.base64EncodedString()))
    XCTAssertEqual(item.string(forType: .string), "<&\"\nfirst\nlast")
  }

  func testChatModeKeepsAllTextAndImages() throws {
    let (image, data) = try dragTestImage(.green)
    let contents = try XCTUnwrap(HistoryDragPayload.contents(items: [historyItem("before"), image, historyItem("after")]))
    let parts = try XCTUnwrap(HistoryDragPayload.chatParts(contents: contents))
    XCTAssertEqual(parts.text, "before\nafter")
    XCTAssertEqual(parts.images.count, 1)
    XCTAssertEqual(parts.images.first?.imageData, data)
  }

  func testImageRecordWithExplicitTextRetainsBoth() throws {
    let (image, data) = try dragTestImage(.red)
    image.contents.append(HistoryItemContent(type: "public.utf8-plain-text", value: "caption".data(using: .utf8)))
    let contents = try XCTUnwrap(HistoryDragPayload.contents(items: [image]))
    XCTAssertEqual(contents.compactMap(\.text), ["caption"])
    XCTAssertEqual(contents.compactMap(\.imageData), [data])
  }

  func testMixedRichDocumentContainsImageAttachment() async throws {
    let (image, _) = try dragTestImage(.red)
    let provider = try XCTUnwrap(HistoryDragPayload.provider(items: [historyItem("before"), image, historyItem("after")]))
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.rtfd.rawValue) { data, error in
        if let error { continuation.resume(throwing: error) }
        else if let data { continuation.resume(returning: data) }
        else { continuation.resume(throwing: CocoaError(.coderInvalidValue)) }
      }
    }
    let document = try XCTUnwrap(NSAttributedString(rtfd: data, documentAttributes: nil))
    XCTAssertTrue(document.string.hasPrefix("before\n"))
    XCTAssertTrue(document.string.hasSuffix("\nafter"))
    XCTAssertNotNil(document.attribute(.attachment, at: 7, effectiveRange: nil))
  }

  func testLocalBuildTranslations() throws {
    for (language, expected) in [("en", "Drag 1 item"), ("zh-Hans", "拖出 1 条记录"), ("zh-Hant", "拖出 1 則記錄")] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      XCTAssertEqual(bundle.localizedString(forKey: "Drag 1 item", value: nil, table: nil), expected)
      XCTAssertNotEqual(bundle.localizedString(forKey: "Raphael local build", value: nil, table: nil), "")
    }
  }

  func testNativeDragSourceClickPreservesModifiers() throws {
    let view = HistoryNativeDragView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    var received: NSEvent.ModifierFlags?
    view.onClick = { received = $0 }
    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
      modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 10, y: 10),
      modifierFlags: .command, timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
    view.mouseDown(with: down)
    view.mouseUp(with: up)
    XCTAssertEqual(received, .command)
  }

  func testUnsupportedDragDoesNotTurnIntoPasteClick() throws {
    let view = HistoryNativeDragView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    var clicked = false
    view.onClick = { _ in clicked = true }
    view.snapshot = { nil }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
      let location = NSPoint(x: type == .leftMouseDown ? 10 : 30, y: 10)
      let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
      if type == .leftMouseDown { view.mouseDown(with: event) }
      else if type == .leftMouseDragged { view.mouseDragged(with: event) }
      else { view.mouseUp(with: event) }
    }
    XCTAssertFalse(clicked)
  }

  func testKeyboardPlainTextRemovesImagesAndAllFormatting() throws {
    let (image, _) = try dragTestImage(.red)
    let item = try XCTUnwrap(HistoryDragPayload.clipboardItem(items: [historyItem("before"), image, historyItem("after")], plainText: true))
    XCTAssertEqual(item.string(forType: .string), "before\nafter")
    XCTAssertEqual(item.types, [.string])
  }

  func testKeyboardRichPasteKeepsTextAndImage() throws {
    let (image, _) = try dragTestImage(.red)
    let item = try XCTUnwrap(HistoryDragPayload.clipboardItem(items: [historyItem("before"), image, historyItem("after")], plainText: false))
    let document = try XCTUnwrap(NSAttributedString(rtfd: try XCTUnwrap(item.data(forType: .rtfd)), documentAttributes: nil))
    XCTAssertEqual(document.string, "before\n\u{fffc}\nafter")
    XCTAssertNotNil(document.attribute(.attachment, at: 7, effectiveRange: nil))
  }

  func testKeyboardPlainTextDoesNotSubstituteOCRForImage() throws {
    let (image, _) = try dragTestImage(.red)
    image.title = "OCR is only a title"
    XCTAssertNil(HistoryDragPayload.clipboardItem(items: [image], plainText: true))
  }

  func testKeyboardPlainTextExtractsRichText() throws {
    let attributed = NSAttributedString(string: "formatted", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
    let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let item = HistoryItem(contents: [HistoryItemContent(type: "public.rtf", value: data)])
    let output = try XCTUnwrap(HistoryDragPayload.clipboardItem(items: [item, historyItem("second")], plainText: true))
    XCTAssertEqual(output.types, [.string])
    XCTAssertEqual(output.string(forType: .string), "formatted\nsecond")
  }

  func testKeyboardRichPasteRetainsOriginalFontStyle() throws {
    let attributed = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
    let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let item = HistoryItem(contents: [HistoryItemContent(type: "public.rtf", value: data)])
    let output = try XCTUnwrap(HistoryDragPayload.clipboardItem(items: [item, historyItem("second")], plainText: false))
    let document = try XCTUnwrap(NSAttributedString(rtfd: try XCTUnwrap(output.data(forType: .rtfd)), documentAttributes: nil))
    let font = try XCTUnwrap(document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    XCTAssertEqual(document.string, "bold\nsecond")
  }

  func testKeyboardPlainTextDoesNotNeedToDecodeImage() throws {
    let image = HistoryItem(contents: [HistoryItemContent(type: "public.png", value: Data([1, 2, 3]))])
    let output = try XCTUnwrap(HistoryDragPayload.clipboardItem(items: [image, historyItem("text")], plainText: true))
    XCTAssertEqual(output.string(forType: .string), "text")
  }

  func testManualSelectionTogglesAndKeepsOrder() {
    let navigator = AppState.shared.navigator
    let first = history.add(historyItem("first"))
    let second = history.add(historyItem("second"))
    navigator.select(item: nil)
    navigator.addToSelection(item: second)
    navigator.addToSelection(item: first)
    XCTAssertEqual(navigator.selection.items, [second, first])
    XCTAssertTrue(navigator.isManualMultiSelect)
    navigator.addToSelection(item: second)
    XCTAssertEqual(navigator.selection.items, [first])
    navigator.addToSelection(item: first)
    XCTAssertTrue(navigator.selection.isEmpty)
    navigator.isManualMultiSelect = false
  }

  func testShiftRangeSelectsVisibleRecords() {
    let navigator = AppState.shared.navigator
    let first = history.add(historyItem("first"))
    let middle = history.add(historyItem("middle"))
    let last = history.add(historyItem("last"))
    navigator.select(item: first)
    navigator.extendSelection(from: first, to: last, isRange: true)
    XCTAssertEqual(Set(navigator.selection.items), Set([first, middle, last]))
    navigator.select(item: nil)
    navigator.isManualMultiSelect = false
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(history.items, [])
  }

  func testAdding() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingSame() {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    history.add(first)
    first.pin = "f"

    let secondDecorator = history.add(historyItem("bar"))

    let third = historyItem("foo")
    third.application = "Xcode.app"
    let merged = history.add(third)

    // The duplicate merges into the existing entry instead of adding a new
    // one, and the merged item carries the original item's metadata.
    // With pinTo = .bottom the unpinned bar sorts first and the re-inserted
    // pinned merged item lands at the end of `all`.
    XCTAssertEqual(history.all, [secondDecorator, merged])
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
  }

  func testAddingItemThatIsSupersededByExisting() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.rtf.rawValue,
        value: "two".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.application = "Maccy.app"
    firstItem.contents = firstContents
    firstItem.title = firstItem.generateTitle()
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.application = "Maccy.app"
    secondItem.contents = secondContents
    secondItem.title = secondItem.generateTitle()
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testAddingItemWithDifferentModifiedType() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "1".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.contents = firstContents
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "2".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.contents = secondContents
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testAddingItemFromMaccy() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      )
    ]
    let first = HistoryItem()
    Storage.shared.context.insert(first)
    first.application = "Xcode.app"
    first.contents = firstContents
    history.add(first)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
        value: "".data(using: .utf8)
      )
    ]
    let second = HistoryItem()
    Storage.shared.context.insert(second)
    second.application = "Maccy.app"
    second.contents = secondContents
    let secondDecorator = history.add(second)

    XCTAssertEqual(history.items, [secondDecorator])
    XCTAssertEqual(history.items[0].item.application, "Xcode.app")
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testModifiedAfterCopying() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let modifiedItemDecorator = history.add(modifiedItem)

    XCTAssertEqual(history.items, [modifiedItemDecorator])
    XCTAssertEqual(history.items[0].text, "bar")
  }

  func testClearingUnpinned() {
    let pinned = history.add(historyItem("foo"))
    pinned.togglePin()
    history.add(historyItem("bar"))
    history.clear()
    XCTAssertEqual(history.items, [pinned])
  }

  func testClearingAll() {
    history.add(historyItem("foo"))
    history.clear()
    XCTAssertEqual(history.items, [])
  }

  func testMaxSize() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[0]))
  }

  func testMaxSizeIgnoresPinned() {
    var items: [HistoryItemDecorator] = []

    let item = history.add(historyItem("0"))
    items.append(item)
    item.togglePin()

    for index in 1...11 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertTrue(history.items.contains(items[0]))
    XCTAssertFalse(history.items.contains(items[1]))
  }

  func testMaxSizeIsChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }
    Defaults[.size] = 5
    history.add(historyItem("11"))

    XCTAssertEqual(history.items.count, 5)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[5]))
  }

  func testReaddingBottomMostPinnedItemAtFullCapacity() {
    // Regression test for a crash when re-copying (invoking) the bottom-most
    // pinned item while history is at full capacity and pins are sorted to the
    // bottom. The stale insert index used to trap with an out-of-bounds insert.
    // Issue link: https://github.com/p0deje/Maccy/issues/1466
    // `pinTo` is restored to its default value(.top) in `tearDown`.
    Defaults[.pinTo] = .bottom

    // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
    // pinned item ends up as the last element.
    let pinned = history.add(historyItem("pinned"))
    history.togglePin(pinned)

    // Fill unpinned history to full capacity.
    for index in 0..<Defaults[.size] {
      history.add(historyItem(String(index)))
    }

    XCTAssertEqual(history.all.last, pinned)

    // Re-copy the pinned item. It is detected as a duplicate, removed and
    // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
    // Before the fix this inserted at a stale, out-of-bounds index and crashed.
    let readded = history.add(historyItem("pinned"))

    XCTAssertTrue(history.all.contains(readded))
    XCTAssertEqual(history.all.filter(\.isPinned).count, 1)
  }

  func testRemoving() {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.delete(foo)
    XCTAssertEqual(history.items, [bar])
  }

  private func historyItem(_ value: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()

    return item
  }
}
