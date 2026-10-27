import AppKit
import KeyboardShortcuts
import SwiftUI

/// First-launch overview of the local features and the two permissions they need.
/// Shown once (flag in UserDefaults); reopen it from Settings → General.
@MainActor
enum WelcomeGuide {
  static let shownKey = "localWelcomeGuideShown"
  private static var window: NSWindow?

  static func showIfNeeded() {
    guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
    show()
  }

  static func show() {
    UserDefaults.standard.set(true, forKey: shownKey)
    if window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
      window.title = NSLocalizedString("Welcome to Shike", comment: "Welcome guide")
      window.titlebarAppearsTransparent = true
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: WelcomeGuideView { WelcomeGuide.close() })
      window.center()
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  static func close() {
    window?.close()
    window = nil
  }
}

private struct WelcomeGuideView: View {
  var done: () -> Void
  @State private var pasteAllowed = Accessibility.allowed
  @State private var captureAllowed = CGPreflightScreenCaptureAccess()
  @State private var imageTools = ImageToolsModule.shared
  @State private var notch = NotchModule.shared

  private func shortcut(_ name: KeyboardShortcuts.Name) -> String {
    name.shortcut?.description ?? NSLocalizedString("not set", comment: "Welcome guide: no shortcut")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
        VStack(alignment: .leading, spacing: 2) {
          Text("Welcome to Shike").font(.title2.weight(.semibold))
          Text("A clipboard history that stays on this Mac.").foregroundStyle(.secondary)
        }
      }

      row("clock.arrow.circlepath", "Clipboard history",
          String(format: NSLocalizedString("Press %@ to open it. Enter pastes, Shift+Enter pastes plain text. ⌘-click or Shift-click to select several items.",
                                           comment: "Welcome guide"), shortcut(.popup)))

      row("capsule", "Notch shelf", NSLocalizedString("Recent items at the top of the screen: click to expand, drag files in or items out.", comment: "Welcome guide")) {
        Toggle("Enable notch shelf", isOn: Binding(get: { notch.enabled }, set: { notch.applyEnabled($0) }))
      }

      row("camera.viewfinder", "Screenshots and OCR",
          String(format: NSLocalizedString("Screenshot: %@ · Screenshot + OCR: %@. Recognized text is copied. Change the shortcuts in Settings → Image Tools.",
                                           comment: "Welcome guide"), shortcut(.captureRegion), shortcut(.captureOCR))) {
        Toggle("Enable screenshot and image tools", isOn: Binding(get: { imageTools.enabled }, set: { imageTools.applyEnabled($0) }))
      }

      row("wand.and.stars", "Image tools",
          NSLocalizedString("Right-click an image in the history to annotate, pin to screen, read text or QR codes, combine images or make a before/after GIF.", comment: "Welcome guide"))

      Divider()

      Text("Permissions").font(.headline)
      permission("Accessibility", "Needed to paste automatically into the app you were using.", allowed: pasteAllowed) {
        Accessibility.check()
        open("Privacy_Accessibility")
      }
      permission("Screen Recording", "Needed for screenshots and screenshot OCR.", allowed: captureAllowed) {
        _ = CGRequestScreenCaptureAccess()
        open("Privacy_ScreenCapture")
      }
      Text("After turning a permission on, quit and reopen Shike if it still shows as missing.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("Open Settings…") { AppState.shared.openPreferences() }
        Spacer()
        Button("Get Started") { done() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 24)
    .frame(width: 560)
    .fixedSize(horizontal: false, vertical: true)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      pasteAllowed = Accessibility.allowed
      captureAllowed = CGPreflightScreenCaptureAccess()
    }
  }

  private func row(_ symbol: String, _ title: LocalizedStringKey, _ detail: String) -> some View {
    row(symbol, title, detail) { EmptyView() }
  }

  private func row<Extra: View>(_ symbol: String, _ title: LocalizedStringKey, _ detail: String,
                                @ViewBuilder extra: () -> Extra) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        extra()
      }
    }
  }

  private func permission(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, allowed: Bool,
                          action: @escaping () -> Void) -> some View {
    HStack(spacing: 12) {
      Image(systemName: allowed ? "checkmark.circle.fill" : "exclamationmark.circle")
        .foregroundStyle(allowed ? .green : .orange).font(.title3).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      if allowed {
        Text("Allowed").foregroundStyle(.secondary)
      } else {
        Button("Open System Settings") { action() }
      }
    }
  }

  private func open(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
      NSWorkspace.shared.open(url)
    }
  }
}
