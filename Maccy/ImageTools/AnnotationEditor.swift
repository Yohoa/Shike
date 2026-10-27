import AppKit
import SwiftUI

enum AnnotationTool: String, CaseIterable, Identifiable {
  case pen = "Pen", arrow = "Arrow", rectangle = "Rectangle", ellipse = "Ellipse"
  case highlight = "Highlighter", text = "Text", step = "Numbered step", redact = "Redact", crop = "Crop"
  var id: String { rawValue }
}

struct ImageMark {
  var tool: AnnotationTool
  var points: [CGPoint]
  var color: NSColor
  var width: CGFloat
  var text: String
  var rect: CGRect {
    guard let first = points.first, let last = points.last else { return .zero }
    return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y))
  }
  func draw() {
    guard let first = points.first, let last = points.last else { return }
    color.setStroke()
    color.setFill()
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    switch tool {
    case .pen, .highlight:
      if tool == .highlight { color.withAlphaComponent(0.28).setStroke(); path.lineWidth = width * 5 }
      path.move(to: first)
      for point in points.dropFirst() { path.line(to: point) }
      path.stroke()
    case .arrow:
      path.move(to: first); path.line(to: last)
      let angle = atan2(last.y - first.y, last.x - first.x)
      for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
        path.move(to: last)
        path.line(to: CGPoint(x: last.x - cos(angle + delta) * width * 5, y: last.y - sin(angle + delta) * width * 5))
      }
      path.stroke()
    case .rectangle: let shape = NSBezierPath(rect: rect); shape.lineWidth = width; shape.stroke()
    case .ellipse: let shape = NSBezierPath(ovalIn: rect); shape.lineWidth = width; shape.stroke()
    case .redact:
      // Opaque pixels are baked into the exported image; there is no reversible blur.
      NSColor.black.setFill(); NSBezierPath(rect: rect).fill()
    case .text:
      (text as NSString).draw(at: first, withAttributes: [.font: NSFont.systemFont(ofSize: width * 6, weight: .semibold), .foregroundColor: color])
    case .step:
      let radius = width * 5
      NSBezierPath(ovalIn: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2)).fill()
      let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: width * 6, weight: .bold), .foregroundColor: NSColor.white]
      let size = (text as NSString).size(withAttributes: attrs)
      (text as NSString).draw(at: CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2), withAttributes: attrs)
    case .crop:
      let selection = NSBezierPath(rect: rect)
      selection.lineWidth = width
      selection.setLineDash([width * 2, width * 2], count: 2, phase: 0)
      selection.stroke()
    }
  }
}

@MainActor
@Observable
final class AnnotationDocument {
  var image: CGImage
  var marks: [ImageMark] = []
  var pending: ImageMark?
  var tool = AnnotationTool.arrow
  var color = Color.red
  var text = ""
  var width: CGFloat = 4
  var revision = 0
  private var undoImages: [Data] = []
  var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
  init(data: Data) throws {
    image = try ImageWorkbench.decode(data, maximumDimension: 4096)
    width = max(4, CGFloat(image.width) / 250)
  }

  func draw(includeCrop: Bool) {
    NSImage(cgImage: image, size: imageSize).draw(in: CGRect(origin: .zero, size: imageSize))
    for mark in marks where includeCrop || mark.tool != .crop { mark.draw() }
    if includeCrop { pending?.draw() }
  }

  func rendered() throws -> CGImage {
    try ImageWorkbench.render(width: image.width, height: image.height) { ctx in
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
      draw(includeCrop: false)
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  func output() throws -> Data { try ImageWorkbench.png(rendered()) }
  func undo() {
    if !marks.isEmpty { marks.removeLast() }
    else if let data = undoImages.popLast(), let restored = try? ImageWorkbench.decode(data, maximumDimension: 8192) { image = restored }
    revision += 1
  }

  func transform(_ action: (CGImage) throws -> CGImage) {
    do {
      let current = try rendered()
      let result = try action(current)
      let old = try ImageWorkbench.png(current)
      undoImages.append(old)
      while undoImages.count > 3 || (undoImages.reduce(0) { $0 + $1.count } > 48_000_000 && undoImages.count > 1) { undoImages.removeFirst() }
      image = result
      marks = []
      pending = nil
      revision += 1
    } catch { ImageToolsModule.shared.showError(error) }
  }

  func crop() {
    guard let selection = marks.last(where: { $0.tool == .crop })?.rect else {
      ImageToolsModule.shared.showMessage(NSLocalizedString("Choose Crop and drag a rectangle on the image first.", comment: "Crop help"))
      return
    }
    let rect = selection.intersection(CGRect(origin: .zero, size: imageSize)).integral
    guard rect.width >= 1, rect.height >= 1 else { return }
    transform { image in
      guard let result = image.cropping(to: CGRect(x: rect.minX, y: CGFloat(image.height) - rect.maxY, width: rect.width, height: rect.height)) else { throw ImageWorkbenchError.invalidImage }
      return result
    }
  }
}

struct AnnotationEditor: View {
  @Bindable var document: AnnotationDocument
  @State private var resizeWidth = ""
  @State private var resizeHeight = ""
  @State private var keepRatio = true
  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Picker("Tool", selection: $document.tool) {
          ForEach(AnnotationTool.allCases) { Text(NSLocalizedString($0.rawValue, comment: "Annotation tool")).tag($0) }
        }.frame(width: 210)
        ColorPicker("Color", selection: $document.color).frame(width: 110)
        Text("Width")
        Slider(value: $document.width, in: 2...max(40, CGFloat(document.image.width) / 40)).frame(width: 90)
        Button("Undo") { document.undo() }.keyboardShortcut("z", modifiers: .command)
        if document.tool == .crop { Button("Apply crop") { document.crop() } }
        Spacer()
      }
      if document.tool == .text {
        TextField("Text to place on the image", text: $document.text)
      }
      AnnotationCanvas(document: document)
        .background(Color(nsColor: .underPageBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      HStack {
        Button("Rotate 90°") { document.transform { try ImageWorkbench.rotated($0) } }
        Button("Flip horizontally") { document.transform { try ImageWorkbench.flipped($0) } }
        Button("Grayscale") { document.transform { try ImageWorkbench.grayscale($0) } }
        Spacer()
        Text("\(document.image.width) × \(document.image.height) px").font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Text("Resize")
        TextField("Width", text: $resizeWidth).frame(width: 65)
        Text("×")
        TextField("Height", text: $resizeHeight).frame(width: 65).disabled(keepRatio)
        Toggle("Keep aspect ratio", isOn: $keepRatio)
        Button("Apply") { resize() }
        Spacer()
      }
      Divider()
      HStack {
        Text("Drag on the image to annotate. Changes create a new image.").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Pin to Screen") { withOutput { ImageToolsModule.shared.pin($0) } }
        Button("Save…") { withOutput { ImageToolsModule.shared.save(data: $0) } }
        Button("Copy image") { withOutput {
          ImageToolsModule.shared.copy(data: $0)
          ImageToolsModule.shared.store(data: $0, type: .png)
        } }.keyboardShortcut("c", modifiers: [.command, .shift])
      }
    }.padding(14).onAppear {
      resizeWidth = String(document.image.width)
      resizeHeight = String(document.image.height)
    }
  }
  private func withOutput(_ action: (Data) -> Void) {
    do { action(try document.output()) } catch { ImageToolsModule.shared.showError(error) }
  }
  private func resize() {
    guard let w = Int(resizeWidth), w > 0, w <= 16384 else { ImageToolsModule.shared.showError(ImageWorkbenchError.tooLarge); return }
    let h = keepRatio ? Int((Double(w) * Double(document.image.height) / Double(document.image.width)).rounded()) : Int(resizeHeight) ?? 0
    document.transform { try ImageWorkbench.resized($0, width: w, height: h) }
    resizeHeight = String(document.image.height)
  }
}

private struct AnnotationCanvas: NSViewRepresentable {
  var document: AnnotationDocument
  func makeNSView(context: Context) -> AnnotationCanvasView { AnnotationCanvasView() }
  func updateNSView(_ view: AnnotationCanvasView, context: Context) {
    _ = document.revision
    _ = document.marks.count
    view.document = document
    view.needsDisplay = true
  }
}

private final class AnnotationCanvasView: NSView {
  var document: AnnotationDocument?
  private var imageRect: CGRect {
    guard let size = document?.imageSize else { return .zero }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    return CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2,
                  width: size.width * scale, height: size.height * scale)
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let document, imageRect.width > 0 else { return }
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: imageRect.minX, byY: imageRect.minY)
    (transform as NSAffineTransform).concat()
    let scale = imageRect.width / document.imageSize.width
    let scaling = AffineTransform(scale: scale)
    (scaling as NSAffineTransform).concat()
    NSBezierPath(rect: CGRect(origin: .zero, size: document.imageSize)).addClip()
    document.draw(includeCrop: true)
    NSGraphicsContext.restoreGraphicsState()
  }
  private func imagePoint(_ event: NSEvent) -> CGPoint? {
    guard let document, imageRect.width > 0 else { return nil }
    let p = convert(event.locationInWindow, from: nil)
    return CGPoint(x: min(max(0, (p.x - imageRect.minX) * document.imageSize.width / imageRect.width), document.imageSize.width),
                   y: min(max(0, (p.y - imageRect.minY) * document.imageSize.height / imageRect.height), document.imageSize.height))
  }
  override func mouseDown(with event: NSEvent) {
    guard let document, imageRect.contains(convert(event.locationInWindow, from: nil)), let p = imagePoint(event) else { return }
    let text = document.tool == .step ? String(document.marks.filter { $0.tool == .step }.count + 1) : document.text
    document.pending = ImageMark(tool: document.tool, points: [p, p], color: NSColor(document.color), width: document.width, text: text)
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard let document, var mark = document.pending, let p = imagePoint(event) else { return }
    if mark.tool == .pen || mark.tool == .highlight { mark.points.append(p) } else { mark.points[mark.points.count - 1] = p }
    document.pending = mark
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    guard let document, let mark = document.pending else { return }
    if mark.tool == .crop { document.marks.removeAll { $0.tool == .crop } }
    if mark.tool != .text || !mark.text.isEmpty { document.marks.append(mark) }
    document.pending = nil
    document.revision += 1
    needsDisplay = true
  }
}
