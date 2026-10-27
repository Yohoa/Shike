import AppKit
import KeyboardShortcuts
import SwiftUI

struct NotchShelfView: View {
  @Bindable var module: NotchModule
  /// This display's shelf state (layout, phase); selection and history are shared by all displays.
  @Bindable var screen: NotchScreen
  private var rect: CGRect { screen.layout.shapeRect(screen.phase) }
  private var radii: (top: CGFloat, bottom: CGFloat) { screen.layout.radii(screen.phase) }
  // Jelly: overshoots when it wakes up, settles back without wobbling.
  private var jelly: Animation {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .easeOut(duration: 0.2) }
    return screen.phase == .idle ? .spring(response: 0.36, dampingFraction: 0.96)
      : .spring(response: 0.44, dampingFraction: 0.68)
  }

  var body: some View {
    let panel = screen.layout.panelFrame
    Group {
      switch screen.phase {
      case .idle: Color.clear
      case .peek: bump.transition(.opacity)
      case .expanded:
        shelf.padding(.horizontal, radii.top)
          .frame(width: rect.width, height: rect.height, alignment: .top)
          .transition(.asymmetric(
            // Content grows out of the notch together with the shape (strong zoom + slight blur-in),
            // and shrinks back toward it on close.
            insertion: .scale(scale: 0.35, anchor: .top).combined(with: .opacity).combined(with: .blur(8)),
            removal: .scale(scale: 0.6, anchor: .top).combined(with: .opacity)))
      }
    }
    .frame(width: rect.width, height: rect.height, alignment: .top)
    .modifier(NotchSurface(module: module, screen: screen, shape: NotchShape(topRadius: radii.top, bottomRadius: radii.bottom)))
    .contentShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
    .offset(x: rect.midX - panel.midX, y: panel.maxY - rect.maxY)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .coordinateSpace(name: NotchHistoryRow.space)
    .animation(jelly, value: screen.phase)
    .environment(\.colorScheme, .dark)
    .onKeyPress(.escape) { module.collapse(); return .handled }
  }

  /// Peek: a subtle bump below the cutout with a grabber; click (or drop) to open.
  private var bump: some View {
    Button { module.expand(on: screen) } label: {
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        if screen.layout.hasCutout {
          Capsule().fill(.white.opacity(0.55)).frame(width: 26, height: 3).padding(.bottom, 4)
        } else {
          Image(systemName: "doc.on.clipboard.fill").font(.system(size: 11)).foregroundStyle(.cyan).padding(.bottom, 4)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .accessibilityLabel(Text("Open notch shelf"))
      .help(Text("Click to open, or drag files here"))
  }

  private var shelf: some View {
    VStack(spacing: 10) {
      if screen.layout.hasCutout { Spacer().frame(height: screen.layout.safeTop + 2) }
      HStack {
        Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.cyan)
        Text("Maccy Notch").font(.headline)
        Spacer()
        if let battery = module.battery {
          Label("\(battery.percent)%", systemImage: battery.charging ? "battery.100percent.bolt" : "battery.100percent")
            .foregroundStyle(battery.percent <= 20 || module.lowPower ? .yellow : .secondary)
            .font(.caption)
            .help(Text(battery.onAC ? "Connected to power" : "On battery"))
        }
        Button { module.collapse() } label: { Image(systemName: "chevron.up.circle.fill") }
          .buttonStyle(.plain).accessibilityLabel(Text("Collapse notch"))
      }.contentShape(Rectangle()).onTapGesture { module.collapse() }
      HStack(spacing: 8) {
        Label(module.dragTarget ? "Drop to add to Maccy" : "Recent clipboard", systemImage: module.dragTarget ? "tray.and.arrow.down.fill" : "clock")
          .font(.caption).foregroundStyle(module.dragTarget ? .white : .secondary)
        Spacer()
        Button("Open Maccy") { module.openHistory() }.buttonStyle(.borderless).font(.caption)
      }
      ScrollView {
        LazyVStack(spacing: 5) {
          let rows = module.recent
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            NotchHistoryRow(row: row, module: module, index: index, isLast: index == rows.count - 1)
          }
          if module.recent.isEmpty {
            Text("Copy something or drop files here to begin.")
              .font(.callout).foregroundStyle(.secondary).padding(25)
          }
        }
      }
      // Copying re-adds the item as the newest history entry (the clicked row is replaced),
      // so the confirmation is a HUD over the list rather than tied to a row.
      .overlay(alignment: .bottom) {
        if module.copiedToast { CopiedHUD().padding(.bottom, 8).transition(.scale(scale: 0.85).combined(with: .opacity)) }
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: module.copiedToast)
      HStack {
        if ImageToolsModule.shared.enabled {
          Button { module.capture(ocr: false) } label: { Image(systemName: "camera.viewfinder") }
            .help(Text("Screenshot"))
          Button("OCR") { module.capture(ocr: true) }.help(Text("Screenshot + OCR"))
        }
        Button { module.openSettings() } label: { Image(systemName: "gearshape") }.help(Text("Preferences…"))
        Text(module.status).font(.caption).foregroundStyle(.cyan).lineLimit(1)
        Spacer(minLength: 0)
        Button("Copy") { module.transfer(paste: false) }.disabled(module.selected.isEmpty)
        Menu {
          Button("Paste") { module.transfer(paste: true) }.keyboardShortcut(.return, modifiers: [])
          Button("Paste plain text") { module.transfer(paste: true, plainText: true) }.keyboardShortcut(.return, modifiers: .shift)
        } label: { Text("Paste") }.disabled(module.selected.isEmpty).fixedSize()
      }.controlSize(.small)
      Text("Click to copy · ⌘ or ⇧ click for multiple · drag to sort or out · force click to preview")
        .font(.system(size: 10)).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).contentShape(Rectangle()).onTapGesture { module.collapse() }
    }.padding(.horizontal, 16).padding(.top, screen.layout.hasCutout ? 0 : 12).padding(.bottom, 12)
      // Empty spots (beside the camera, gaps, padding) collapse. This sits *behind* the content so the
      // rows' AppKit click/drag handles never also trigger it (selecting must keep the shelf open).
      .background { Color.clear.contentShape(Rectangle()).onTapGesture { module.collapse() } }
  }
}

private struct NotchHistoryRow: View {
  @Bindable var row: HistoryItemDecorator
  @Bindable var module: NotchModule
  var index: Int
  var isLast: Bool
  static let space = "notchRoot"
  private var selected: Bool { module.selectedIDs.contains(row.id) }
  private var items: [HistoryItem] { selected ? module.selected : [row.item] }
  /// Dragging a selected row moves the whole selection; otherwise just this row.
  private var dragIDs: [UUID] { selected ? module.selectedIDs : [row.id] }
  var body: some View {
    HStack(spacing: 8) {
      Button { module.select(row.id, multiple: true) } label: {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? .cyan : .secondary)
      }.buttonStyle(.plain).frame(width: 22)
      if let image = row.thumbnailImage {
        Image(nsImage: image).resizable().scaledToFit().frame(width: 30, height: 28)
      } else {
        Image(systemName: !row.item.fileURLs.isEmpty ? "doc.fill" : row.hasImage ? "photo" : "text.alignleft")
          .frame(width: 24).foregroundStyle(.secondary)
      }
      Text(row.hasImage ? (row.title.isEmpty ? NSLocalizedString("Image", comment: "Notch image") : row.title.shortened(to: 160)) : row.item.previewableText.shortened(to: 160))
        .lineLimit(1).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
      if row.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
    }
    .padding(.horizontal, 7).frame(height: 34)
    .background(selected ? Color.accentColor.opacity(0.4) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      HistoryNativeDragHandle(items: items, onClick: { flags in module.click(row.id, flags: flags) }, excludedLeadingWidth: 30,
                              onForceClick: { anchor in module.preview(row, from: anchor) },
                              contextMenu: { anchor in module.contextMenu(for: row, anchor: anchor) },
                              reorderIDs: dragIDs)
    }
    .overlay(alignment: .top) { if module.dropIndex == index { insertionLine.offset(y: -3) } }
    .overlay(alignment: .bottom) { if isLast && module.dropIndex == index + 1 { insertionLine.offset(y: 3) } }
    .background {
      GeometryReader { proxy in
        let frame = proxy.frame(in: .named(Self.space))
        Color.clear
          .onAppear { module.rowFrames[row.id] = frame }
          .onChange(of: frame) { _, new in module.rowFrames[row.id] = new }
          .onDisappear { module.rowFrames[row.id] = nil }
      }
    }
    .onAppear { row.ensureThumbnailImage() }
  }
  private var insertionLine: some View {
    Capsule().fill(Color.cyan).frame(height: 2).padding(.horizontal, 4).allowsHitTesting(false)
  }
}

struct NotchSettings: View {
  @State private var module = NotchModule.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Toggle("Enable notch shelf", isOn: Binding(get: { module.enabled }, set: { module.applyEnabled($0) }))
      Text("A small clipboard shelf at the top of your screen. Click to expand, drag files in, or drag clipboard items out. Displays without a camera notch get a floating pill.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle("Show on all displays", isOn: Binding(get: { module.allDisplays }, set: { module.setAllDisplays($0) }))
        .disabled(!module.enabled)
      Picker("Display", selection: Binding(get: { module.displayID }, set: { module.chooseDisplay($0) })) {
        Text("Automatic (prefer camera notch)").tag(0)
        ForEach(NSScreen.screens, id: \.localizedName) { screen in
          Text(screen.localizedName).tag(NotchModule.displayID(of: screen))
        }
      }.disabled(module.allDisplays)
      HStack { Text("Open notch shelf"); Spacer(); KeyboardShortcuts.Recorder(for: .notchShelf).disabled(!module.enabled) }
      Button("Show notch shelf") { if !module.enabled { module.applyEnabled(true) }; module.expand() }
      Text("Battery updates use system notifications. Turning this off removes the window, shortcut and observers. No extra permissions are needed for the shelf.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }.padding(24).frame(width: 500)
  }
}

struct NotchLauncher: View {
  @State private var module = NotchModule.shared
  var body: some View {
    HStack {
      Button {
        if !module.enabled { module.applyEnabled(true) }
        module.expand()
      } label: { Label("Notch", systemImage: "capsule.tophalf.filled") }
      .buttonStyle(.borderless)
      Spacer()
      if module.enabled {
        Button("Hide notch") { module.applyEnabled(false) }.buttonStyle(.borderless).foregroundStyle(.secondary)
      }
    }.font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
  }
}

/// Idle stays solid black so it disappears into the camera housing. Once awake it becomes
/// Liquid Glass (macOS 26+), keeping a black block over the cutout so the camera area stays solid.
private struct NotchSurface<S: Shape>: ViewModifier {
  @Bindable var module: NotchModule
  @Bindable var screen: NotchScreen
  var shape: S
  private var glass: Bool { screen.phase == .expanded && !module.dragTarget }
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .background(alignment: .top) { cutoutBlock }
        .background(glass ? Color.black.opacity(0.3) : (module.dragTarget ? Color.accentColor.opacity(0.95) : Color.black))
        .background {
          // The glass edge highlight runs along every side of its shape. Extend the glass above the
          // screen's top edge (off-window) so no bright rim is drawn along the top of the display.
          if glass {
            Color.clear
              .glassEffect(.regular.tint(.black.opacity(0.55)),
                           in: UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26))
              .padding(.top, -24)
          }
        }
        .clipShape(shape)
    } else {
      content
        .background(module.dragTarget ? Color.accentColor.opacity(0.95) : Color.black)
        .clipShape(shape)
    }
  }
  @ViewBuilder private var cutoutBlock: some View {
    if glass && screen.layout.hasCutout {
      UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
        .fill(.black)
        .frame(width: screen.layout.bodySize(.idle).width, height: screen.layout.bodySize(.idle).height)
    }
  }
}

/// Notch silhouette: flat top flush with the bezel, concave shoulders flaring into the
/// sides, then rounded bottom corners. Both radii animate so the shape morphs with the spring.
nonisolated struct NotchShape: Shape {
  var topRadius: CGFloat
  var bottomRadius: CGFloat
  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(topRadius, bottomRadius) }
    set { topRadius = newValue.first; bottomRadius = newValue.second }
  }
  func path(in rect: CGRect) -> Path {
    let t = min(topRadius, rect.width / 4, rect.height / 2)
    let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
    var p = Path()
    p.move(to: CGPoint(x: rect.minX, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
    p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
    p.closeSubpath()
    return p
  }
}

private struct BlurTransition: ViewModifier {
  var radius: CGFloat
  func body(content: Content) -> some View { content.blur(radius: radius) }
}

private extension AnyTransition {
  static func blur(_ radius: CGFloat) -> AnyTransition {
    .modifier(active: BlurTransition(radius: radius), identity: BlurTransition(radius: 0))
  }
}

/// System-style HUD: compact capsule, Liquid Glass on macOS 26 (material before), green checkmark.
private struct CopiedHUD: View {
  var body: some View {
    let label = HStack(spacing: 6) {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      Text("Copied").foregroundStyle(.primary)
    }
    .font(.system(size: 12, weight: .semibold))
    .padding(.horizontal, 14).padding(.vertical, 7)
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    if #available(macOS 26, *) {
      label.glassEffect(.regular, in: Capsule())
    } else {
      label.background(.regularMaterial, in: Capsule())
    }
  }
}
