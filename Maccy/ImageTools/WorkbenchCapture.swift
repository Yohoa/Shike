import AppKit
import ScreenCaptureKit

@MainActor
final class WorkbenchCapture {
  private var panels: [NSPanel] = []
  private var continuation: CheckedContinuation<(NSScreen, CGRect)?, Never>?

  func cancel() { finish(nil) }

  func capture(window: Bool = false) async throws -> CGImage? {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      throw NSError(domain: "MaccyImageTools", code: 1, userInfo: [NSLocalizedDescriptionKey:
        NSLocalizedString("Allow Maccy Fixed in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.", comment: "Screen capture permission")])
    }
    AppState.shared.popup.close()
    if window { try await Task.sleep(for: .milliseconds(200)) }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let config = SCStreamConfiguration()
    config.showsCursor = false
    if window {
      let windows = content.windows.filter {
        $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 80
          && $0.frame.height > 60 && !($0.title ?? "").isEmpty && $0.windowLayer == 0
      }
      guard !windows.isEmpty else { throw ImageWorkbenchError.invalidImage }
      let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
      picker.addItems(withTitles: windows.map { "\($0.owningApplication?.applicationName ?? "") — \($0.title ?? "")" })
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("Capture window…", comment: "Capture chooser")
      alert.accessoryView = picker
      alert.addButton(withTitle: NSLocalizedString("Capture", comment: "Capture action"))
      alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel"))
      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else { return nil }
      let target = windows[picker.indexOfSelectedItem]
      config.width = Int(target.frame.width * 2)
      config.height = Int(target.frame.height * 2)
      try ImageWorkbench.validate(width: config.width, height: config.height)
      return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
    }
    // Like the system screenshot: freeze every display first (open menus, hover states and all), then
    // select on that still image. Nothing activates or takes focus before the pixels are captured,
    // so another app's open menu stays in the shot instead of being dismissed by our overlay.
    let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
    var frozen: [(screen: NSScreen, image: CGImage)] = []
    for screen in NSScreen.screens {
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
            let display = content.displays.first(where: { $0.displayID == id }) else { continue }
      let full = SCStreamConfiguration()
      full.showsCursor = false
      full.width = Int(screen.frame.width * screen.backingScaleFactor)
      full.height = Int(screen.frame.height * screen.backingScaleFactor)
      let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own),
                                                             configuration: full)
      frozen.append((screen, image))
    }
    guard !frozen.isEmpty, let (screen, rect) = await selectRegion(frozen) else { return nil }
    guard let image = frozen.first(where: { $0.screen == screen })?.image else { throw ImageWorkbenchError.invalidImage }
    let scale = CGFloat(image.width) / screen.frame.width
    let pixels = CGRect(x: rect.minX * scale, y: (screen.frame.height - rect.maxY) * scale,
                        width: rect.width * scale, height: rect.height * scale).integral
    try ImageWorkbench.validate(width: Int(pixels.width), height: Int(pixels.height))
    return image.cropping(to: pixels)
  }

  private func selectRegion(_ frozen: [(screen: NSScreen, image: CGImage)]) async -> (NSScreen, CGRect)? {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      for (screen, image) in frozen {
        // Non-activating: the overlay takes keys (Esc) and mouse without activating Maccy.
        let panel = CapturePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = CaptureRegionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.frozen = NSImage(cgImage: image, size: screen.frame.size)
        view.completion = { [weak self] rect in self?.finish(rect.map { (screen, $0) }) }
        panel.contentView = view
        panels.append(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
      }
    }
  }

  private func finish(_ result: sending (NSScreen, CGRect)?) {
    panels.forEach { $0.orderOut(nil) }
    panels.removeAll()
    let pending = continuation
    continuation = nil
    pending?.resume(returning: result)
  }
}

private final class CapturePanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

private final class CaptureRegionView: NSView {
  var completion: ((CGRect?) -> Void)?
  /// Still image of this display taken before the overlay appeared.
  var frozen: NSImage?
  private var start: NSPoint?
  private var rect = CGRect.zero
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
  override func draw(_ dirtyRect: NSRect) {
    frozen?.draw(in: bounds)
    let shade = NSBezierPath(rect: bounds)
    if !rect.isEmpty { shade.appendRect(rect) }
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.35).setFill()
    shade.fill()
    NSColor.white.setStroke()
    NSBezierPath(rect: rect).stroke()
    let help = NSLocalizedString("Drag to capture · Esc to cancel", comment: "Capture overlay")
    (help as NSString).draw(at: NSPoint(x: 24, y: bounds.height - 60), withAttributes: [
      .font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white
    ])
  }
  override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil) }
  override func mouseDragged(with event: NSEvent) {
    guard let start else { return }
    let p = convert(event.locationInWindow, from: nil)
    rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x), height: abs(start.y - p.y)).intersection(bounds)
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    mouseDragged(with: event)
    completion?(rect.width >= 3 && rect.height >= 3 ? rect : nil)
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { completion?(nil) } else { super.keyDown(with: event) }
  }
}
