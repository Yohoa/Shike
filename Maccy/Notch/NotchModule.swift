import AppKit
import IOKit.ps
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
  static let notchShelf = Self("localNotchShelf")
}

/// One display's shelf: its own panel, geometry and open state.
@MainActor
@Observable
final class NotchScreen {
  let displayID: Int
  var layout: NotchLayout
  var phase: NotchPhase = .idle
  @ObservationIgnored fileprivate var panel: NotchPanel?
  @ObservationIgnored fileprivate var hoverTask: Task<Void, Never>?
  var host: NotchHostingView? { panel?.contentView as? NotchHostingView }
  init(displayID: Int, layout: NotchLayout) {
    self.displayID = displayID
    self.layout = layout
  }
}

@MainActor
@Observable
final class NotchModule {
  static let shared = NotchModule()
  var enabled = UserDefaults.standard.bool(forKey: "localNotchEnabled")
  /// Shelves currently shown: the chosen display, or every display when `allDisplays` is on.
  var screens: [NotchScreen] = []
  var expandedScreen: NotchScreen? { screens.first { $0.phase == .expanded } }
  var expanded: Bool { expandedScreen != nil }
  var displayID = UserDefaults.standard.integer(forKey: "localNotchDisplay")
  var allDisplays = UserDefaults.standard.bool(forKey: "localNotchAllDisplays")
  var battery: NotchBattery?
  var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  var selectedIDs: [UUID] = []
  @ObservationIgnored private var selectionAnchor: UUID?
  var dragTarget = false
  @ObservationIgnored private var menuOpen = false
  @ObservationIgnored private var menuObservers: [NSObjectProtocol] = []
  var status = ""
  var displayRevision = 0
  @ObservationIgnored private var screenObserver: NSObjectProtocol?
  @ObservationIgnored private var powerObserver: NSObjectProtocol?
  @ObservationIgnored private var powerSource: CFRunLoopSource?
  @ObservationIgnored private var feedbackTask: Task<Void, Never>?
  @ObservationIgnored private var scopedFiles: [URL] = []
  @ObservationIgnored private var didStart = false

  /// Order the user set by dragging rows. Only IDs are stored; history itself is untouched.
  var manualOrder: [UUID] = (UserDefaults.standard.stringArray(forKey: "localNotchOrder") ?? []).compactMap(UUID.init)
  /// Insertion slot shown while a row is being dragged within the shelf.
  var dropIndex: Int?
  /// Shows the "Copied" HUD over the list.
  var copiedToast = false
  @ObservationIgnored private var flashTask: Task<Void, Never>?
  /// Row frames in the shelf's root coordinate space, for drop-slot hit testing.
  @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
  @ObservationIgnored private var previewPopover: NSPopover?
  var previewOpen: Bool { previewPopover?.isShown == true }

  var recent: [HistoryItemDecorator] {
    // Observe the existing history's mutations. No separate index, polling or decoded originals.
    _ = History.shared.items
    let base = Array(History.shared.all.prefix(8))
    let ids = Self.arrange(base.map(\.id), order: manualOrder)
    return ids.compactMap { id in base.first { $0.id == id } }
  }

  /// New items (not yet ordered by the user) stay on top in Maccy's order; the rest follow the manual order.
  static func arrange(_ ids: [UUID], order: [UUID]) -> [UUID] {
    let fresh = ids.filter { !order.contains($0) }
    let known = ids.filter { order.contains($0) }.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
    return fresh + known
  }
  /// Moves `moved` (kept in their current relative order) so they start at slot `index` of `ids`.
  static func moving(_ ids: [UUID], moved: [UUID], to index: Int) -> [UUID] {
    let block = ids.filter { moved.contains($0) }
    var rest = ids.filter { !moved.contains($0) }
    let insertAt = ids.prefix(max(0, min(index, ids.count))).filter { !moved.contains($0) }.count
    rest.insert(contentsOf: block, at: insertAt)
    return rest
  }
  func slot(at point: CGPoint) -> Int {
    recent.filter { (rowFrames[$0.id]?.midY ?? .infinity) < point.y }.count
  }
  func reorder(_ moved: [UUID], to index: Int) {
    dropIndex = nil
    let ids = recent.map(\.id)
    let result = Self.moving(ids, moved: moved, to: index)
    guard result != ids else { return }
    manualOrder = result
    UserDefaults.standard.set(result.map(\.uuidString), forKey: "localNotchOrder")
  }

  /// Force Touch preview, anchored beside the row. Released when closed or replaced.
  func preview(_ row: HistoryItemDecorator, from anchor: NSView) {
    previewPopover?.close()
    let popover = NSPopover()
    popover.behavior = .semitransient
    popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    popover.contentViewController = NSHostingController(rootView:
      PreviewItemView(item: row).padding(14).frame(width: 420, height: 380))
    previewPopover = popover  // set first: showing it may resign the panel's key status
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
  }
  func closePreview() {
    previewPopover?.close()
    previewPopover = nil
  }

  /// Right-click menu for a row; acts on the selection when the row is part of it.
  func contextMenu(for row: HistoryItemDecorator, anchor: NSView) -> NSMenu {
    if !selectedIDs.contains(row.id) { select(row.id, multiple: false) }
    let items = selected
    let menu = NSMenu()
    func add(_ title: String, _ action: @escaping () -> Void) {
      menu.addItem(WorkbenchMenuItem(title: NSLocalizedString(title, comment: "Notch context menu"), action: action))
    }
    add("Copy") { [weak self] in self?.transfer(paste: false) }
    add("Paste") { [weak self] in self?.transfer(paste: true) }
    add("Paste plain text") { [weak self] in self?.transfer(paste: true, plainText: true) }
    add("Preview") { [weak self, weak anchor] in
      guard let self, let anchor else { return }
      self.preview(row, from: anchor)
    }
    menu.addItem(.separator())
    add(row.isPinned ? "Unpin" : "Pin") { History.shared.togglePin(row) }
    if !row.item.fileURLs.isEmpty {
      add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(row.item.fileURLs) }
    }
    if let tools = ImageToolsModule.shared.menu(items: items), !tools.items.isEmpty {
      menu.addItem(.separator())
      for item in tools.items { tools.removeItem(item); menu.addItem(item) }
    }
    menu.addItem(.separator())
    add(items.count > 1 ? "Delete Selected" : "Delete") { [weak self] in
      guard let self else { return }
      let rows = self.recent.filter { self.selectedIDs.contains($0.id) }
      self.selectedIDs = []
      rows.forEach { History.shared.delete($0) }
    }
    return menu
  }
  var selected: [HistoryItem] {
    selectedIDs.compactMap { id in recent.first(where: { $0.id == id })?.item }
  }

  func start() {
    guard !didStart else { return }
    didStart = true
    KeyboardShortcuts.onKeyUp(for: .notchShelf) { [weak self] in self?.toggle() }
    applyEnabled(enabled)
  }

  func applyEnabled(_ value: Bool) {
    enabled = value
    UserDefaults.standard.set(value, forKey: "localNotchEnabled")
    if value {
      KeyboardShortcuts.enable(.notchShelf)
      guard screens.isEmpty else { return }
      readPower()
      screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.displayRevision += 1; self?.reposition() }
      }
      powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.readPower() }
      }
      let context = Unmanaged.passUnretained(self).toOpaque()
      powerSource = IOPSNotificationCreateRunLoopSource({ context in
        guard let context else { return }
        let module = Unmanaged<NotchModule>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in module.readPower() }
      }, context)?.takeRetainedValue()
      if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
      // Keep the shelf open while its Paste menu is tracking (the menu steals the pointer).
      menuObservers = [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)].map { name, open in
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in
            guard let self else { return }
            self.menuOpen = open && self.expanded
            if !open, let screen = self.expandedScreen {
              self.hover(screen, screen.layout.hoverRect(screen.phase).contains(NSEvent.mouseLocation))
            }
          }
        }
      }
      reposition()
    } else {
      KeyboardShortcuts.disable(.notchShelf)
      menuObservers.forEach(NotificationCenter.default.removeObserver)
      menuObservers = []
      menuOpen = false
      selectedIDs = []
      dragTarget = false
      feedbackTask?.cancel()
      feedbackTask = nil
      if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
      if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
      screenObserver = nil
      powerObserver = nil
      if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
      powerSource = nil
      screens.forEach(teardown)
      screens = []
      scopedFiles.forEach { $0.stopAccessingSecurityScopedResource() }
      scopedFiles = []
      status = ""
    }
  }

  func chooseDisplay(_ id: Int) {
    displayID = id
    UserDefaults.standard.set(id, forKey: "localNotchDisplay")
    reposition()
  }

  func setAllDisplays(_ value: Bool) {
    allDisplays = value
    UserDefaults.standard.set(value, forKey: "localNotchAllDisplays")
    reposition()
  }

  static func displayID(of screen: NSScreen) -> Int {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
  }

  /// Creates, moves or removes one panel per target display. Existing shelves keep their state.
  func reposition() {
    guard enabled else { return }
    let targets: [NSScreen]
    if allDisplays {
      targets = NSScreen.screens
    } else {
      let chosen = NSScreen.screens.first { Self.displayID(of: $0) == displayID }
        ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
      targets = chosen.map { [$0] } ?? []
    }
    var next: [NotchScreen] = []
    for display in targets {
      let id = Self.displayID(of: display)
      let layout = NotchLayout(screen: display)
      let slot = screens.first { $0.displayID == id } ?? makeScreen(id: id, layout: layout)
      slot.layout = layout
      // Fixed-size panel; only the shape animates and only `hitRect` takes clicks.
      if slot.panel?.frame != layout.panelFrame { slot.panel?.setFrame(layout.panelFrame, display: true) }
      slot.host?.refreshTracking()
      slot.panel?.orderFrontRegardless()
      next.append(slot)
    }
    for old in screens where !next.contains(where: { $0 === old }) { teardown(old) }
    screens = next
  }

  private func makeScreen(id: Int, layout: NotchLayout) -> NotchScreen {
    let slot = NotchScreen(displayID: id, layout: layout)
    let window = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.title = NSLocalizedString("Maccy Notch", comment: "Notch window")
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.isReleasedWhenClosed = false
    window.level = .statusBar  // higher levels break drop-target lookup
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    window.hidesOnDeactivate = false
    window.module = self
    window.slot = slot
    window.contentView = NotchHostingView(module: self, screen: slot)
    slot.panel = window
    return slot
  }

  private func teardown(_ slot: NotchScreen) {
    slot.hoverTask?.cancel()
    slot.phase = .idle
    slot.panel?.orderOut(nil)
    slot.panel?.contentView = nil
    slot.panel?.close()
    slot.panel = nil
  }

  private func setPhase(_ slot: NotchScreen, _ new: NotchPhase) {
    guard new != slot.phase else { return }
    slot.phase = new
    slot.host?.refreshTracking()
  }

  /// Pointer entered/left a shelf's hover rect (tracking area, no global mouse monitoring).
  func hover(_ slot: NotchScreen, _ inside: Bool) {
    slot.hoverTask?.cancel()
    guard enabled else { return }
    if inside {
      if slot.phase == .idle { setPhase(slot, .peek) }
      return
    }
    guard slot.phase != .idle else { return }
    let delay = slot.phase == .expanded ? 0.5 : 0.12
    slot.hoverTask = Task { [weak self, weak slot] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, let slot, self.enabled else { return }
      if slot.phase == .peek { self.setPhase(slot, .idle) }
      else if slot.phase == .expanded, self.selectedIDs.isEmpty, !self.dragTarget, !self.menuOpen, !self.previewOpen { self.collapse() }
    }
  }

  func toggle() {
    guard enabled else { return }
    if expanded { collapse() } else { expand() }
  }
  /// Opens the shelf on `slot`, else on the display under the pointer, else the first one.
  func expand(on slot: NotchScreen? = nil) {
    guard enabled else { return }
    let mouse = NSEvent.mouseLocation
    guard let target = slot ?? screens.first(where: { $0.layout.screenFrame.contains(mouse) }) ?? screens.first else { return }
    if let current = expandedScreen {
      guard current !== target else { return }
      collapse()  // only one shelf is open at a time
    }
    target.hoverTask?.cancel()
    Clipboard.shared.capturePasteTarget()
    AppState.shared.popup.close()
    selectedIDs = []
    setPhase(target, .expanded)
    target.panel?.makeKeyAndOrderFront(nil)
  }
  func collapse() {
    closePreview()
    dropIndex = nil
    selectedIDs = []
    dragTarget = false
    guard let slot = expandedScreen else { return }
    slot.hoverTask?.cancel()
    defer { slot.panel?.resignKey() }  // after the phase change, so NotchPanel.resignKey doesn't re-enter
    guard enabled else { slot.phase = .idle; return }
    let pointerNear = slot.layout.hitRect(.peek).contains(NSEvent.mouseLocation)
    setPhase(slot, pointerNear ? .peek : .idle)
  }
  func select(_ id: UUID, multiple: Bool) {
    if multiple {
      if selectedIDs.contains(id) { selectedIDs.removeAll { $0 == id } } else { selectedIDs.append(id) }
    } else { selectedIDs = [id] }
    selectionAnchor = id
  }
  /// Shift-click: add every row between the anchor and `id` (in list order), keeping existing picks.
  func selectRange(to id: UUID, order: [UUID]? = nil) {
    let order = order ?? recent.map(\.id)
    guard let anchor = selectionAnchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
      select(id, multiple: false)
      return
    }
    let range = from <= to ? Array(order[from...to]) : Array(order[to...from].reversed())
    selectedIDs += range.filter { !selectedIDs.contains($0) }
  }
  /// Plain click copies that row (shelf stays open); ⇧ extends, ⌘ toggles a multiple selection.
  func click(_ id: UUID, flags: NSEvent.ModifierFlags) {
    if flags.contains(.shift) { selectRange(to: id); return }
    if flags.contains(.command) { select(id, multiple: true); return }
    // Copy without leaving a selection: Maccy re-adds the copied content as a new top entry, so a
    // highlighted row would flash blue and then vanish when that row is replaced.
    selectedIDs = []
    selectionAnchor = id
    guard let item = recent.first(where: { $0.id == id })?.item else { return }
    Clipboard.shared.copy(item)
    flashCopied()
  }

  func transfer(paste: Bool, plainText: Bool = false) {
    let items = selected
    guard !items.isEmpty else { return }
    if items.count == 1, !plainText {
      Clipboard.shared.copy(items[0])
    } else if !Clipboard.shared.copyCombined(items, plainText: plainText) {
      feedback("This selection cannot be combined. Copy files one at a time.")
      return
    }
    if paste {
      collapse()
      Clipboard.shared.paste()
    } else { flashCopied() }
  }

  func openHistory() {
    collapse()
    AppState.shared.popup.open(height: AppState.shared.popup.height)
  }
  func openSettings() {
    collapse()
    AppState.shared.openPreferences()
  }
  func capture(ocr: Bool) {
    collapse()
    ImageToolsModule.shared.capture(ocr: ocr)
  }

  func acceptDrop(_ pasteboard: NSPasteboard) -> Bool {
    guard enabled else { return false }
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    let payload: [HistoryItemContent]
    if !urls.isEmpty {
      guard urls.count <= 100 else { feedback("Drop at most 100 files at once."); return false }
      for url in urls where !scopedFiles.contains(url) {
        if url.startAccessingSecurityScopedResource() { scopedFiles.append(url) }
      }
      while scopedFiles.count > 100 { scopedFiles.removeFirst().stopAccessingSecurityScopedResource() }
      payload = urls.map { HistoryItemContent(type: NSPasteboard.PasteboardType.fileURL.rawValue, value: $0.dataRepresentation) }
    } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
      guard let image = try? ImageWorkbench.decode(data, maximumDimension: 4096), let png = try? ImageWorkbench.png(image) else { return false }
      payload = [HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: png)]
    } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
      payload = [HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: Data(text.utf8))]
    } else { return false }
    let item = HistoryItem(contents: payload)
    item.application = Bundle.main.bundleIdentifier
    if #unavailable(macOS 15) { try? History.shared.insertIntoStorage(item) }
    item.title = item.generateTitle()
    History.shared.add(item)
    dragTarget = false
    feedback("Added to Maccy")
    return true
  }

  private func flashCopied() {
    flashTask?.cancel()
    copiedToast = true
    flashTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1100))
      guard !Task.isCancelled else { return }
      self?.copiedToast = false
    }
  }

  func feedback(_ key: String) {
    feedbackTask?.cancel()
    status = NSLocalizedString(key, comment: "Notch feedback")
    feedbackTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.status = ""
    }
  }
  private func readPower() {
    lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { battery = nil; return }
    battery = nil
    for source in list {
      guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
      battery = NotchBattery(current: desc[kIOPSCurrentCapacityKey] as? Int, maximum: desc[kIOPSMaxCapacityKey] as? Int,
                             charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                             onAC: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
      break
    }
  }
}

fileprivate final class NotchPanel: NSPanel {
  weak var module: NotchModule?
  weak var slot: NotchScreen?
  override var canBecomeKey: Bool { slot?.phase == .expanded }
  override var canBecomeMain: Bool { false }
  /// Clicking anywhere outside the shelf (another app, the desktop) closes it.
  override func resignKey() {
    super.resignKey()
    // Keep the shelf while its own preview popover or a menu holds focus.
    if slot?.phase == .expanded, module?.previewOpen != true {
      module?.collapse()
    }
  }
  override func cancelOperation(_ sender: Any?) { module?.collapse() }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { module?.collapse(); return }
    if event.keyCode == 36 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
      module?.transfer(paste: true, plainText: event.modifierFlags.contains(.shift))
      return
    }
    super.keyDown(with: event)
  }
}

final class NotchHostingView: NSHostingView<NotchShelfView> {
  weak var module: NotchModule?
  weak var screen: NotchScreen?
  private var expandedForDrag = false
  private var tracking: NSTrackingArea?
  init(module: NotchModule, screen: NotchScreen) {
    self.module = module
    self.screen = screen
    super.init(rootView: NotchShelfView(module: module, screen: screen))
    sizingOptions = []
    registerForDraggedTypes([.fileURL, .string, .png, .tiff])
  }
  required init(rootView: NotchShelfView) { super.init(rootView: rootView) }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private func local(_ screenRect: CGRect) -> CGRect {
    guard let window else { return .zero }
    return convert(window.convertFromScreen(screenRect), from: nil)
  }
  func refreshTracking() {
    if let tracking { removeTrackingArea(tracking) }
    guard let screen, window != nil else { tracking = nil; return }
    let area = NSTrackingArea(rect: local(screen.layout.hoverRect(screen.phase)),
                              options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    refreshTracking()
  }
  /// Transparent parts of the fixed panel pass clicks through to the menu bar / apps below.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let screen, let superview else { return nil }
    let rect = local(screen.layout.hitRect(screen.phase))
    guard rect.contains(convert(point, from: superview)) else { return nil }
    // Closed (idle/peek): the trigger zone is mostly transparent SwiftUI space with nothing to hit,
    // so a click there was dropped — e.g. on displays without a camera notch. Take it here instead.
    return screen.phase == .expanded ? super.hitTest(point) : self
  }
  override func mouseDown(with event: NSEvent) {
    guard let screen, screen.phase != .expanded else { super.mouseDown(with: event); return }
    module?.expand(on: screen)
  }
  override func mouseEntered(with event: NSEvent) { if let screen { module?.hover(screen, true) } }
  override func mouseExited(with event: NSEvent) { if let screen { module?.hover(screen, false) } }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// A row of this shelf being dragged back onto it means "reorder", not "add to history".
  private func reorderIDs(_ sender: NSDraggingInfo) -> [UUID]? {
    guard let source = sender.draggingSource as? HistoryNativeDragView, source.window === window,
          !source.reorderIDs.isEmpty else { return nil }
    return source.reorderIDs
  }
  private func rootPoint(_ sender: NSDraggingInfo) -> CGPoint {
    var point = convert(sender.draggingLocation, from: nil)
    if !isFlipped { point.y = bounds.height - point.y }
    return point
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let module, module.enabled else { return [] }
    if reorderIDs(sender) != nil {
      module.dropIndex = module.slot(at: rootPoint(sender))
      return .move
    }
    expandedForDrag = !module.expanded
    module.expand(on: screen)
    module.dragTarget = true
    return .copy
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard let module, reorderIDs(sender) != nil else { return .copy }
    let slot = module.slot(at: rootPoint(sender))
    if module.dropIndex != slot { module.dropIndex = slot }
    return .move
  }
  override func draggingExited(_ sender: NSDraggingInfo?) {
    module?.dropIndex = nil
    module?.dragTarget = false
    if expandedForDrag { module?.collapse() }
    expandedForDrag = false
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { module?.enabled == true }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    expandedForDrag = false
    if let module, let ids = reorderIDs(sender) {
      module.reorder(ids, to: module.slot(at: rootPoint(sender)))
      return true
    }
    return module?.acceptDrop(sender.draggingPasteboard) ?? false
  }
}
