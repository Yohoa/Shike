import AppKit
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
  static let captureRegion = Self("localCaptureRegion")
  // ⌘⇧O by default; only applied while no value is stored, so a recorded or cleared shortcut is kept.
  static let captureOCR = Self("localCaptureOCR", initial: Shortcut(.o, modifiers: [.command, .shift]))
}

@MainActor
@Observable
final class ImageToolsModule {
  static let shared = ImageToolsModule()
  static let enabledKey = "localImageToolsEnabled"
  var enabled = UserDefaults.standard.bool(forKey: enabledKey)
  static let resultWindowKey = "localOCRShowWindow"
  /// OCR / QR results are always copied; this additionally opens the result window (off by default).
  var showResultWindow = UserDefaults.standard.bool(forKey: resultWindowKey) {
    didSet { UserDefaults.standard.set(showResultWindow, forKey: Self.resultWindowKey) }
  }
  var busy = false
  private var windows: [UUID: WorkbenchWindow] = [:]
  private var worker: Task<Void, Never>?
  private let captureService = WorkbenchCapture()

  func start() {
    KeyboardShortcuts.onKeyUp(for: .captureRegion) { [weak self] in self?.capture(ocr: false) }
    KeyboardShortcuts.onKeyUp(for: .captureOCR) { [weak self] in self?.capture(ocr: true) }
    applyEnabled(enabled)
  }

  func applyEnabled(_ value: Bool) {
    enabled = value
    AppState.shared.navigator.pointerSelectionEnabled = !value
    AppState.shared.navigator.hoverSelectionWhileKeyboardNavigating = nil
    UserDefaults.standard.set(value, forKey: Self.enabledKey)
    if value {
      KeyboardShortcuts.enable(.captureRegion, .captureOCR)
    } else {
      KeyboardShortcuts.disable(.captureRegion, .captureOCR)
      worker?.cancel()
      captureService.cancel()
      busy = false
      let open = Array(windows.values)
      open.forEach { $0.close() }
    }
  }

  func capture(ocr: Bool, window: Bool = false) {
    guard enabled, !busy else { return }
    busy = true
    if ocr { Task.detached(priority: .utility) { ImageWorkbench.warmUpTextRecognition() } }
    worker = Task {
      defer { busy = false }
      do {
        guard let image = try await captureService.capture(window: window), enabled, !Task.isCancelled else { return }
        let data = try ImageWorkbench.png(image)
        if ocr {
          try await recognizeData(data, qr: false)
        } else {
          store(data: data, type: .png)
          editor(data)
        }
      } catch {
        if !Task.isCancelled && enabled { showError(error) }
      }
    }
  }

  func editor(_ data: Data) {
    guard enabled else { return }
    do {
      let model = try AnnotationDocument(data: data)
      AppState.shared.popup.close()
      present(title: tr("Annotate…"), view: AnnotationEditor(document: model), size: NSSize(width: 1000, height: 760))
    } catch { showError(error) }
  }

  func pin(_ data: Data) {
    guard enabled else { return }
    do {
      let image = try ImageWorkbench.decode(data, maximumDimension: 2048)
      let ratio = CGFloat(image.height) / CGFloat(image.width)
      var width: CGFloat = 420, height = width * ratio
      if height > 600 { height = 600; width = height / ratio }
      let model = PinModel()
      AppState.shared.popup.close()
      let window = present(title: tr("Pin to Screen"), view: PinnedImageView(image: NSImage(cgImage: image, size: .zero), model: model),
                           size: NSSize(width: width.rounded(), height: height.rounded()), floating: true, chromeless: true,
                           hover: { model.hovering = $0 })
      model.close = { [weak window] in window?.close() }
    } catch { showError(error) }
  }

  func recognize(_ data: Data, qr: Bool) {
    guard enabled, !busy else { return }
    busy = true
    AppState.shared.popup.close()
    worker = Task {
      defer { busy = false }
      do { try await recognizeData(data, qr: qr) }
      catch { if enabled && !Task.isCancelled { showError(error) } }
    }
  }

  private func recognizeData(_ data: Data, qr: Bool) async throws {
    let started = Date()
    let result = try await Task.detached(priority: .userInitiated) {
      try autoreleasepool { try ImageWorkbench.recognize(data, qr: qr) }
    }.value
    WorkbenchCapture.log.info("recognized \(result.count, privacy: .public) chars in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
    guard enabled, !Task.isCancelled else { return }
    store(data: Data(result.utf8), type: .string)
    Clipboard.shared.copyTextForDrag(result)
    if showResultWindow {
      present(title: tr(qr ? "Scan QR Code" : "Run OCR"), view: RecognitionResultView(text: result), size: NSSize(width: 640, height: 420))
    } else {
      ToastHUD.show(String(format: tr("Text copied (%d characters)"), result.count))
    }
  }

  func combine(_ items: [HistoryItem], gif: Bool = false, vertical: Bool = false) {
    guard enabled, !busy else { return }
    AppState.shared.popup.close()
    var data = items.compactMap(\.imageData)
    if data.count < 2 {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.image]
      panel.allowsMultipleSelection = !gif
      panel.message = tr("Choose images to combine with the selected image.")
      guard panel.runModal() == .OK else { return }
      do { data += try panel.urls.map { try Data(contentsOf: $0, options: .mappedIfSafe) } }
      catch { showError(error); return }
    }
    guard data.count >= 2 else { showError(ImageWorkbenchError.invalidImage); return }
    if gif && data.count != 2 { showMessage(tr("Select exactly two images for a before/after GIF.")); return }
    busy = true
    let input = data
    worker = Task {
      defer { busy = false }
      do {
        let output = try await Task.detached(priority: .userInitiated) {
          try autoreleasepool {
            var images: [CGImage] = []
            var pixels = 0
            for data in input {
              let image = try ImageWorkbench.decode(data, maximumDimension: 4096)
              pixels += image.width * image.height
              guard pixels <= ImageWorkbench.pixelLimit else { throw ImageWorkbenchError.tooLarge }
              images.append(image)
            }
            return try gif ? ImageWorkbench.gif(images[0], images[1]) : ImageWorkbench.png(ImageWorkbench.combined(images, vertical: vertical))
          }
        }.value
        guard enabled, !Task.isCancelled else { return }
        store(data: output, type: gif ? NSPasteboard.PasteboardType("com.compuserve.gif") : .png)
        copy(data: output, type: gif ? NSPasteboard.PasteboardType("com.compuserve.gif") : .png)
        if gif { save(data: output, gif: true) } else { editor(output) }
      } catch { if enabled && !Task.isCancelled { showError(error) } }
    }
  }

  func copy(data: Data, type: NSPasteboard.PasteboardType = .png) {
    let item = NSPasteboardItem()
    item.setData(data, forType: type)
    item.setString("", forType: .fromMaccy)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([item])
  }

  func store(data: Data, type: NSPasteboard.PasteboardType) {
    let item = HistoryItem(contents: [HistoryItemContent(type: type.rawValue, value: data)])
    item.application = Bundle.main.bundleIdentifier
    // Keep the existing macOS 14 insertion contract used by Clipboard.
    if #unavailable(macOS 15) { try? History.shared.insertIntoStorage(item) }
    item.title = item.generateTitle()
    History.shared.add(item)
  }

  func save(data: Data, gif: Bool = false) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = gif ? [.gif] : [.png]
    panel.nameFieldStringValue = gif ? "Shike-before-after.gif" : "Shike-image.png"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try data.write(to: url, options: .atomic) } catch { showError(error) }
  }

  func menu(items: [HistoryItem]) -> NSMenu? {
    guard enabled, items.contains(where: { $0.imageData != nil }) else { return nil }
    let menu = NSMenu()
    func add(_ title: String, _ action: @escaping @MainActor () -> Void) { menu.addItem(WorkbenchMenuItem(title: tr(title), action: action)) }
    add("Annotate…") { if let data = items.first(where: { $0.imageData != nil })?.imageData { self.editor(data) } }
    add("Pin to Screen") { if let data = items.first(where: { $0.imageData != nil })?.imageData { self.pin(data) } }
    add("Run OCR") { if let data = items.first(where: { $0.imageData != nil })?.imageData { self.recognize(data, qr: false) } }
    add("Scan QR Code") { if let data = items.first(where: { $0.imageData != nil })?.imageData { self.recognize(data, qr: true) } }
    menu.addItem(.separator())
    let tools = NSMenu()
    tools.addItem(WorkbenchMenuItem(title: tr("Combine with…")) { self.combine(items) })
    tools.addItem(WorkbenchMenuItem(title: tr("Combine vertically…")) { self.combine(items, vertical: true) })
    tools.addItem(WorkbenchMenuItem(title: tr("Before / After GIF…")) { self.combine(items, gif: true) })
    let parent = NSMenuItem(title: tr("Image Tools"), action: nil, keyEquivalent: "")
    parent.submenu = tools
    menu.addItem(parent)
    return menu
  }

  /// `chromeless`: no title bar or border, a transparent window around the content (pinned images); `hover` then
  /// reports the pointer entering and leaving it so the content can show its controls only while it is near.
  @discardableResult
  func present<V: View>(title: String, view: V, size: NSSize, floating: Bool = false, chromeless: Bool = false,
                        hover: ((Bool) -> Void)? = nil) -> NSWindow? {
    guard windows.count < 6 else { showMessage(tr("Close an image tools window before opening another.")); return nil }
    let id = UUID()
    let window = WorkbenchWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: chromeless ? [.borderless, .resizable] : [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    if chromeless {
      let host = HoverHostingView(rootView: view)
      host.onHover = hover
      window.contentView = host
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = true
      window.isMovableByWindowBackground = true
      window.contentAspectRatio = size
      window.minSize = NSSize(width: 120, height: (120 * size.height / size.width).rounded())
      window.pinKeys = true
      window.originalSize = size
    } else {
      window.contentView = NSHostingView(rootView: view)
      window.minSize = NSSize(width: floating ? 180 : 600, height: floating ? 120 : 400)
    }
    window.level = floating ? .floating : .normal
    if floating { window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] }
    window.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
    window.delegate = window
    windows[id] = window
    window.center()
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    return window
  }

  func showError(_ error: Error) { showMessage(error.localizedDescription) }
  func showMessage(_ message: String) {
    let alert = NSAlert()
    alert.messageText = tr("Image Tools")
    alert.informativeText = message
    alert.runModal()
  }
  func tr(_ key: String) -> String { NSLocalizedString(key, comment: "Image tools") }
}

nonisolated final class WorkbenchMenuItem: NSMenuItem {
  private let handler: @MainActor () -> Void
  init(title: String, action: @escaping @MainActor () -> Void) {
    handler = action
    super.init(title: title, action: #selector(invoke), keyEquivalent: "")
    target = self
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  @MainActor @objc private func invoke() { handler() }
}

private final class HoverHostingView<Content: View>: NSHostingView<Content> {
  var onHover: ((Bool) -> Void)?
  private var hoverArea: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    // Always active: the pinned image is rarely the key window, and the controls should still appear.
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }
  override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?(true) }
  override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover?(false) }
}

private final class WorkbenchWindow: NSWindow, NSWindowDelegate {
  var onClose: (() -> Void)?
  /// Pinned images: ⌘= / ⌘- zoom, ⌘0 returns to the first size.
  var pinKeys = false
  var originalSize = NSSize.zero
  override var canBecomeKey: Bool { true }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard pinKeys, event.modifierFlags.intersection([.command, .option, .control]) == .command else {
      return super.performKeyEquivalent(with: event)
    }
    switch event.charactersIgnoringModifiers {
    case "=", "+": zoom(by: 1.15)
    case "-": zoom(by: 1 / 1.15)
    case "0": zoom(to: originalSize.width)
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }
  private func zoom(by factor: CGFloat) { zoom(to: frame.width * factor) }
  /// Resizes around the window's centre, keeping the aspect ratio, between the minimum and the screen.
  private func zoom(to requested: CGFloat) {
    let area = (screen ?? NSScreen.main)?.visibleFrame ?? frame
    let ratio = frame.height / frame.width
    let width = min(max(requested, minSize.width), area.width, area.height / ratio).rounded()
    let size = NSSize(width: width, height: (width * ratio).rounded())
    var target = NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    target.origin.x = min(max(target.minX, area.minX), area.maxX - target.width)
    target.origin.y = min(max(target.minY, area.minY), area.maxY - target.height)
    setFrame(target, display: true, animate: true)
  }
  func windowWillClose(_ notification: Notification) {
    contentView = nil
    onClose?()
    onClose = nil
  }
}

struct RecognitionResultView: View {
  @State var text: String
  var body: some View {
    VStack(alignment: .leading) {
      Text("Recognized text is copied. Review it before pasting.").foregroundStyle(.secondary)
      TextEditor(text: $text).font(.body).border(Color.secondary.opacity(0.2))
      HStack {
        Button("Copy text") { Clipboard.shared.copyTextForDrag(text) }
        Button("Save to history") { ImageToolsModule.shared.store(data: Data(text.utf8), type: .string) }
        Spacer()
      }
    }.padding()
  }
}

@Observable
final class PinModel {
  var hovering = false
  var opacity = 1.0
  var close: () -> Void = {}
}

/// Dragging anywhere on the picture moves the window. A SwiftUI hosting view never lets a plain click move its window
/// (`isMovableByWindowBackground` has no effect on it), so this AppKit view sits behind the picture and starts the
/// drag itself; the buttons and the slider above it still get their own clicks.
private struct WindowDragHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ view: NSView, context: Context) {}
  final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }
}

/// A pinned image: just the picture until the pointer comes near, then a border, a close button and an opacity slider
/// (like iPhone Mirroring's title bar). The window itself is transparent, so lowering the opacity shows what is behind.
struct PinnedImageView: View {
  let image: NSImage
  var model: PinModel
  private let corner: CGFloat = 10

  var body: some View {
    Image(nsImage: image).resizable().scaledToFit()
      .opacity(model.opacity)
      .background(WindowDragHandle())
      .overlay(alignment: .top) {
        HStack(spacing: 8) {
          Button { model.close() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
            .buttonStyle(.plain).help(NSLocalizedString("Close", comment: "Close"))
          Image(systemName: "circle.lefthalf.filled").font(.system(size: 11))
          Slider(value: Binding(get: { model.opacity }, set: { model.opacity = $0 }), in: 0.15...1)
            .controlSize(.mini).frame(maxWidth: 120)
            .help(NSLocalizedString("Opacity", comment: "Pinned image opacity"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(8)
        .opacity(model.hovering ? 1 : 0)
      }
      .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
        .opacity(model.hovering ? 1 : 0))
      .clipShape(RoundedRectangle(cornerRadius: corner))
      .animation(.easeInOut(duration: 0.15), value: model.hovering)
      .contextMenu { Button("Close") { model.close() } }
  }
}

struct ImageToolsBar: View {
  @Environment(AppState.self) private var appState
  @State private var module = ImageToolsModule.shared
  private var items: [HistoryItem] { appState.navigator.selection.items.map(\.item) }
  var body: some View {
    if module.enabled {
      HStack {
        Menu {
          Button("Capture region…") { module.capture(ocr: false) }
          Button("Capture window…") { module.capture(ocr: false, window: true) }
          Button("Screenshot + OCR") { module.capture(ocr: true) }
        } label: { Label("Screenshot", systemImage: "camera.viewfinder") }
        Menu {
          Button("Annotate…") { if let data = items.first(where: { $0.imageData != nil })?.imageData { module.editor(data) } }
          Button("Pin to Screen") { if let data = items.first(where: { $0.imageData != nil })?.imageData { module.pin(data) } }
          Button("Run OCR") { if let data = items.first(where: { $0.imageData != nil })?.imageData { module.recognize(data, qr: false) } }
          Button("Scan QR Code") { if let data = items.first(where: { $0.imageData != nil })?.imageData { module.recognize(data, qr: true) } }
          Divider()
          Button("Combine with…") { module.combine(items) }
          Button("Combine vertically…") { module.combine(items, vertical: true) }
          Button("Before / After GIF…") { module.combine(items, gif: true) }
        } label: { Label("Image Tools", systemImage: "wand.and.stars") }
        .disabled(!items.contains(where: { $0.imageData != nil }))
        Spacer()
        if module.busy { ProgressView().controlSize(.small) }
      }.menuStyle(.borderlessButton).disabled(module.busy).padding(.horizontal, 10).padding(.vertical, 4)
    }
  }
}

struct ImageToolsSettings: View {
  @State private var module = ImageToolsModule.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Enable screenshot and image tools", isOn: Binding(get: { module.enabled }, set: { module.applyEnabled($0) }))
      Text("Capture, annotate, pin, recognize text or QR codes, combine images and create before/after GIFs. Processing stays on this Mac.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack { Text("Screenshot"); Spacer(); KeyboardShortcuts.Recorder(for: .captureRegion).disabled(!module.enabled) }
      HStack { Text("Screenshot + OCR"); Spacer(); KeyboardShortcuts.Recorder(for: .captureOCR).disabled(!module.enabled) }
      Picker("OCR and QR results", selection: $module.showResultWindow) {
        Text("Copy to clipboard").tag(false)
        Text("Copy and show in a window").tag(true)
      }.disabled(!module.enabled)
      Text("Use the image menu or right-click an image. Select multiple images in order to combine them.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.padding(24).frame(width: 500)
  }
}

/// Brief, non-interactive confirmation shown at the top of the active screen.
@MainActor
enum ToastHUD {
  private static var panel: NSPanel?
  private static var hideTask: Task<Void, Never>?

  static func show(_ message: String) {
    hideTask?.cancel()
    panel?.orderOut(nil)
    let host = NSHostingView(rootView: ToastHUDView(message: message))
    // The window must not track the SwiftUI content size: auto-resizing during layout re-entered
    // constraint updates and AppKit aborted the app ("Update Constraints in Window" loop).
    host.sizingOptions = []
    let fitting = host.fittingSize
    let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
    host.frame = NSRect(origin: .zero, size: size)
    guard let screen = NSScreen.main else { return }
    let frame = NSRect(x: screen.frame.midX - size.width / 2,
                       y: screen.visibleFrame.maxY - size.height - 12, width: size.width, height: size.height)
    let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .statusBar
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    window.contentView = host
    window.alphaValue = 0
    window.orderFrontRegardless()
    panel = window
    NSAnimationContext.runAnimationGroup { $0.duration = 0.18; window.animator().alphaValue = 1 }
    hideTask = Task {
      try? await Task.sleep(for: .seconds(1.6))
      guard !Task.isCancelled else { return }
      NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; window.animator().alphaValue = 0 }) {
        Task { @MainActor in
          window.orderOut(nil)
          if panel === window { panel = nil }
        }
      }
    }
  }
}

private struct ToastHUDView: View {
  var message: String
  var body: some View {
    let label = HStack(spacing: 6) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      Text(message)
    }
    .font(.system(size: 13, weight: .semibold))
    .padding(.horizontal, 16).padding(.vertical, 9)
    if #available(macOS 26, *) {
      label.glassEffect(.regular, in: Capsule()).padding(6)
    } else {
      label.background(.regularMaterial, in: Capsule()).padding(6)
    }
  }
}
