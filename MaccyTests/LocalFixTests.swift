import AppKit
import Defaults
import XCTest
@testable import Maccy

/// Local Fix tests (drag payloads, memory cleanup, selection) carried over from 2.7.1.
@MainActor
final class LocalFixTests: XCTestCase { // swiftlint:disable:this type_body_length
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

  func testDecoratorIsReleasedWithoutChangingObservedProperties() {
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    weak var decorator: HistoryItemDecorator?
    autoreleasepool {
      let candidate = HistoryItemDecorator(item)
      decorator = candidate
    }
    XCTAssertNil(decorator)
  }

  func testImageCleanupAllowsRegeneration() async {
    let image = NSImage(named: "StatusBarMenuImage")!
    let decorator = historyItemDecorator(image)
    decorator.ensureThumbnailImage()
    decorator.ensurePreviewImage()
    _ = await decorator.thumbnailImageGenerationTask?.result
    _ = await decorator.previewImageGenerationTask?.result
    XCTAssertNotNil(decorator.thumbnailImage)
    XCTAssertNotNil(decorator.previewImage)
    decorator.cleanupImages()
    XCTAssertNil(decorator.thumbnailImageGenerationTask)
    XCTAssertNil(decorator.previewImageGenerationTask)
    decorator.ensureThumbnailImage()
    decorator.ensurePreviewImage()
    _ = await decorator.thumbnailImageGenerationTask?.result
    _ = await decorator.previewImageGenerationTask?.result
    XCTAssertNotNil(decorator.thumbnailImage)
    XCTAssertNotNil(decorator.previewImage)
  }

  func testResizedImageDoesNotRetainSource() {
    weak var source: NSImage?
    var thumbnail: NSImage?
    autoreleasepool {
      let image = NSImage(size: NSSize(width: 400, height: 400))
      image.lockFocus()
      NSColor.red.setFill()
      NSRect(x: 0, y: 0, width: 400, height: 400).fill()
      image.unlockFocus()
      source = image
      thumbnail = image.resized(to: NSSize(width: 40, height: 40))
    }
    XCTAssertNil(source)
    XCTAssertEqual(thumbnail?.size, NSSize(width: 40, height: 40))
    XCTAssertNotNil(thumbnail?.tiffRepresentation)
  }

  func testCancelledImageTasksDoNotRepopulateCaches() async {
    let decorator = historyItemDecorator(NSImage(named: "StatusBarMenuImage")!)
    decorator.ensureThumbnailImage()
    decorator.ensurePreviewImage()
    decorator.cleanupImages()
    await Task.yield()
    XCTAssertNil(decorator.thumbnailImage)
    XCTAssertNil(decorator.previewImage)
  }

  func testPreviewCleanupPreservesThumbnailAndAllowsRegeneration() async {
    let decorator = historyItemDecorator(NSImage(named: "StatusBarMenuImage")!)
    decorator.sizeImages()
    decorator.cleanupPreviewImage()
    XCTAssertNotNil(decorator.thumbnailImage)
    XCTAssertNil(decorator.previewImage)
    let preview = await decorator.asyncGetPreviewImage()
    XCTAssertNotNil(preview)
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

  private func historyItemDecorator(_ value: NSImage) -> HistoryItemDecorator {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.tiff.rawValue,
        value: value.tiffRepresentation!
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()
    item.application = "com.apple.finder"
    item.firstCopiedAt = Date()
    item.lastCopiedAt = Date()
    item.numberOfCopies = 2

    return HistoryItemDecorator(item)
  }
}
