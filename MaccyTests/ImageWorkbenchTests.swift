import AppKit
import CoreImage
import ImageIO
import XCTest
@testable import Maccy

@MainActor
final class ImageWorkbenchTests: XCTestCase {
  private func solid(_ color: CGColor, width: Int = 80, height: Int = 40) throws -> CGImage {
    try ImageWorkbench.render(width: width, height: height) { ctx in
      ctx.setFillColor(color)
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }
  private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
    try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
  }
  func testCombineKeepsSelectionOrderAndPixels() throws {
    let red = try solid(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let blue = try solid(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    let combined = try ImageWorkbench.combined([red, blue], vertical: false, gap: 10)
    XCTAssertEqual(combined.width, 170)
    XCTAssertEqual(combined.height, 40)
    XCTAssertGreaterThan(try color(combined, x: 10, y: 10).redComponent, 0.95)
    XCTAssertGreaterThan(try color(combined, x: 100, y: 10).blueComponent, 0.95)
    let stacked = try ImageWorkbench.combined([red, blue], vertical: true, gap: 10)
    XCTAssertEqual(stacked.width, 80)
    XCTAssertEqual(stacked.height, 90)
    XCTAssertGreaterThan(try color(stacked, x: 10, y: 10).redComponent, 0.95)
    XCTAssertGreaterThan(try color(stacked, x: 10, y: 65).blueComponent, 0.95)
  }
  func testGIFHasTwoFramesSameCanvasAndLoopTiming() throws {
    let first = try solid(CGColor(gray: 0, alpha: 1))
    let second = try solid(CGColor(gray: 1, alpha: 1), width: 40, height: 80)
    let data = try ImageWorkbench.gif(first, second)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    XCTAssertEqual(CGImageSourceGetCount(source), 2)
    for index in 0..<2 {
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
      XCTAssertEqual(image.width, 80); XCTAssertEqual(image.height, 80)
      let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
      let gif = try XCTUnwrap(props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
      XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime] as? Double), 0.8, accuracy: 0.01)
    }
  }
  func testGIFIsRecognizedAsHistoryImageWithoutFlattening() throws {
    let image = try solid(CGColor(gray: 1, alpha: 1))
    let data = try ImageWorkbench.gif(image, image)
    let item = HistoryItem(contents: [HistoryItemContent(type: "com.compuserve.gif", value: data)])
    XCTAssertEqual(item.imageData, data)
    XCTAssertNotNil(item.image)
    item.clearDecodedImageCache()
  }
  func testRejectsUnboundedOutputAndCorruptInput() {
    XCTAssertThrowsError(try ImageWorkbench.validate(width: 16384, height: 16384))
    XCTAssertThrowsError(try ImageWorkbench.validate(width: 0, height: 1))
    XCTAssertThrowsError(try ImageWorkbench.decode(Data("not an image".utf8)))
  }
  func testOpaqueRedactionSurvivesPNGAndCropUndo() throws {
    let image = try solid(CGColor(gray: 1, alpha: 1), width: 100, height: 100)
    let document = try AnnotationDocument(data: ImageWorkbench.png(image))
    document.marks.append(ImageMark(tool: .redact, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60)], color: .red, width: 4, text: ""))
    let rendered = try ImageWorkbench.decode(document.output())
    let center = try color(rendered, x: 40, y: 50)
    XCTAssertLessThan(center.redComponent, 0.01)
    XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01)
    document.marks.append(ImageMark(tool: .crop, points: [CGPoint(x: 10, y: 10), CGPoint(x: 70, y: 80)], color: .red, width: 4, text: ""))
    document.crop()
    XCTAssertEqual(document.image.width, 60); XCTAssertEqual(document.image.height, 70)
    document.undo()
    XCTAssertEqual(document.image.width, 100); XCTAssertEqual(document.image.height, 100)
    XCTAssertTrue(document.marks.isEmpty)
  }
  func testRecognizesQRPayloadWithoutOpeningIt() throws {
    let payload = "https://example.com/maccy-local-test"
    let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    let ci = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let image = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent))
    XCTAssertEqual(try ImageWorkbench.recognize(ImageWorkbench.png(image), qr: true), payload)
  }
  func testOCRRecognizesActualRenderedText() throws {
    let image = try ImageWorkbench.render(width: 1000, height: 180) { ctx in
      ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 180))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
      ("Maccy screenshot OCR 2026" as NSString).draw(at: CGPoint(x: 30, y: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 50), .foregroundColor: NSColor.black])
      NSGraphicsContext.restoreGraphicsState()
    }
    let text = try ImageWorkbench.recognize(ImageWorkbench.png(image), qr: false)
    XCTAssertTrue(text.contains("screenshot OCR 2026"), text)
  }
  func testRotationFlipAndResizeKeepDimensionsAndPNG() throws {
    let input = try solid(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    let rotated = try ImageWorkbench.rotated(input)
    XCTAssertEqual(rotated.width, 40); XCTAssertEqual(rotated.height, 80)
    XCTAssertGreaterThan(try color(rotated, x: 10, y: 10).redComponent, 0.95)
    let flipped = try ImageWorkbench.flipped(input)
    XCTAssertEqual(flipped.width, 80)
    let resized = try ImageWorkbench.resized(input, width: 20, height: 10)
    XCTAssertEqual(try ImageWorkbench.decode(ImageWorkbench.png(resized)).width, 20)
  }
  func testEditorDoesNotRetainImageAfterClosing() throws {
    weak var released: AnnotationDocument?
    try autoreleasepool {
      let image = try solid(CGColor(gray: 1, alpha: 1))
      let document = try AnnotationDocument(data: ImageWorkbench.png(image))
      released = document
      XCTAssertNotNil(released)
    }
    XCTAssertNil(released)
  }
}

@MainActor
final class ToastHUDTests: XCTestCase {
  /// Regression: the OCR toast once aborted the app with an "Update Constraints in Window" loop.
  func testToastShowsAndDismissesWithoutLayoutLoop() {
    ToastHUD.show("Text copied (12 characters)")
    ToastHUD.show("Text copied (3 characters)")  // replacing a visible toast
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))
  }
}

@MainActor
final class PopupFadeOCRTests: XCTestCase {
  /// Regression: OCR closed the popup and stored its result while the popup was still fading,
  /// which looped SwiftUI's animated window sizing until AppKit aborted.
  func testStoringWhilePopupClosesDoesNotLoopLayout() {
    guard AppState.shared.appDelegate?.panel != nil else { return }
    let wasEnabled = ImageToolsModule.shared.enabled
    ImageToolsModule.shared.enabled = true
    defer { ImageToolsModule.shared.enabled = wasEnabled }
    AppState.shared.popup.open(height: AppState.shared.popup.height)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    ImageToolsModule.shared.busy = true
    AppState.shared.popup.close()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    ImageToolsModule.shared.store(data: Data("ocr text".utf8), type: .string)
    ImageToolsModule.shared.busy = false
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    XCTAssertTrue(AppState.shared.popup.isClosed())
  }
}
