import AppKit
import XCTest
@testable import Maccy

@MainActor
final class NotchTests: XCTestCase {
  func testNotchedLayoutKeepsCameraAreaClearAndTopAnchored() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let layout = NotchLayout(frame: screen, safeTop: 32,
      left: CGRect(x: 0, y: 950, width: 650, height: 32),
      right: CGRect(x: 862, y: 950, width: 650, height: 32))
    XCTAssertTrue(layout.hasCutout)
    XCTAssertEqual(layout.centerWidth, 212)
    for phase in [NotchPhase.idle, .peek, .expanded] {
      XCTAssertEqual(layout.shapeRect(phase).midX, 756)
      XCTAssertEqual(layout.shapeRect(phase).maxY, screen.maxY)
      XCTAssertTrue(layout.panelFrame.contains(layout.hoverRect(phase).intersection(screen)))
    }
    XCTAssertGreaterThan(layout.shapeRect(.expanded).height, layout.shapeRect(.peek).height)
  }
  func testIdleNotchNeverExceedsTheCameraCutout() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let layout = NotchLayout(frame: screen, safeTop: 32,
      left: CGRect(x: 0, y: 950, width: 650, height: 32),
      right: CGRect(x: 862, y: 950, width: 650, height: 32))
    XCTAssertEqual(layout.shapeRect(.idle), CGRect(x: 650, y: 950, width: 212, height: 32))
    // Peek is only a small bump; the trigger zone stays stable and covers it.
    XCTAssertLessThanOrEqual(layout.shapeRect(.peek).width - layout.shapeRect(.idle).width, 32)
    XCTAssertTrue(layout.hitRect(.idle).contains(layout.shapeRect(.peek)))
    XCTAssertEqual(layout.hitRect(.idle), layout.hitRect(.peek))
    let plain = NotchLayout(frame: screen, safeTop: 0)
    XCTAssertLessThanOrEqual(plain.shapeRect(.idle).height, 6)
    XCTAssertTrue(screen.contains(plain.panelFrame))
  }
  func testExternalDisplayUsesPillAndSupportsNegativeCoordinates() {
    let screen = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
    let layout = NotchLayout(frame: screen, safeTop: 0)
    XCTAssertFalse(layout.hasCutout)
    XCTAssertEqual(layout.shapeRect(.peek).midX, screen.midX)
    XCTAssertEqual(layout.shapeRect(.peek).maxY, screen.maxY)
    XCTAssertTrue(screen.contains(layout.panelFrame))
    XCTAssertTrue(layout.panelFrame.contains(layout.shapeRect(.expanded)))
  }
  func testSmallScreenClampsExpandedFrameWithinDisplay() {
    let screen = CGRect(x: 100, y: 100, width: 420, height: 300)
    let layout = NotchLayout(frame: screen, safeTop: 0)
    XCTAssertTrue(screen.contains(layout.shapeRect(.expanded)))
    XCTAssertTrue(screen.contains(layout.panelFrame))
    XCTAssertLessThan(layout.shapeRect(.expanded).width, 420)
  }
  func testManualOrderKeepsNewItemsOnTopAndMovesBlocks() {
    let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
    // d is new (never sorted) so it stays first; the rest follow the saved order.
    XCTAssertEqual(NotchModule.arrange([d, a, b, c], order: [c, a, b]), [d, c, a, b])
    XCTAssertEqual(NotchModule.moving([a, b, c, d], moved: [d], to: 0), [d, a, b, c])
    XCTAssertEqual(NotchModule.moving([a, b, c, d], moved: [a], to: 4), [b, c, d, a])
    XCTAssertEqual(NotchModule.moving([a, b, c, d], moved: [a, c], to: 3), [b, a, c, d])
    XCTAssertEqual(NotchModule.moving([a, b, c, d], moved: [b], to: 2), [a, b, c, d])
  }
  func testBatteryConvertsCapacityAndPreservesChargingState() throws {
    let battery = try XCTUnwrap(NotchBattery(current: 24, maximum: 80, charging: true, onAC: true))
    XCTAssertEqual(battery.percent, 30)
    XCTAssertTrue(battery.charging)
    XCTAssertTrue(battery.onAC)
  }
  func testBatteryHandlesMissingOrInvalidReadings() {
    XCTAssertNil(NotchBattery(current: nil, maximum: 100, charging: false, onAC: false))
    XCTAssertNil(NotchBattery(current: 2, maximum: 0, charging: false, onAC: false))
    XCTAssertEqual(NotchBattery(current: 200, maximum: 100, charging: false, onAC: false)?.percent, 100)
    XCTAssertEqual(NotchBattery(current: -1, maximum: 100, charging: false, onAC: false)?.percent, 0)
  }
  func testNotchMultiSelectionKeepsClickOrderAndCanToggleOff() {
    let module = NotchModule()
    let first = UUID(), second = UUID(), third = UUID()
    module.select(second, multiple: false)
    module.select(first, multiple: true)
    XCTAssertEqual(module.selectedIDs, [second, first])
    module.select(second, multiple: true)
    XCTAssertEqual(module.selectedIDs, [first])
    module.select(third, multiple: false)
    XCTAssertEqual(module.selectedIDs, [third])
    // Shift-click extends from the anchor through the list order, in either direction.
    module.selectRange(to: first, order: [first, second, third])
    XCTAssertEqual(module.selectedIDs, [third, second, first])
    module.select(second, multiple: false)
    module.selectRange(to: third, order: [first, second, third])
    XCTAssertEqual(module.selectedIDs, [second, third])
  }
  func testDisabledNotchRejectsDropWithoutTouchingHistory() {
    let module = NotchModule()
    module.enabled = false
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }
    pb.setString("not added", forType: .string)
    let before = History.shared.items.count
    XCTAssertFalse(module.acceptDrop(pb))
    XCTAssertEqual(History.shared.items.count, before)
  }
  func testImageToolsClickSelectsWhileModifierActionsStillWork() {
    XCTAssertTrue(HistoryRowClickPolicy.selectsOnly(imageToolsEnabled: true, flags: []))
    XCTAssertTrue(HistoryRowClickPolicy.selectsOnly(imageToolsEnabled: true, flags: [.capsLock]))
    XCTAssertFalse(HistoryRowClickPolicy.selectsOnly(imageToolsEnabled: false, flags: []))
    XCTAssertFalse(HistoryRowClickPolicy.selectsOnly(imageToolsEnabled: true, flags: [.option]))
    XCTAssertFalse(HistoryRowClickPolicy.selectsOnly(imageToolsEnabled: true, flags: [.command]))
    XCTAssertFalse(HistoryRowClickPolicy.selectsOnly(imageToolsEnabled: true, flags: [.shift]))
  }
  func testLeavingKeyboardNavigationCannotReplaceExplicitSelectionWithHoveredFooter() {
    let footer = Footer()
    let navigator = NavigationManager(history: History.shared, footer: footer)
    let selected = HistoryItemDecorator(HistoryItem(contents: []))
    navigator.select(item: selected)
    navigator.pointerSelectionEnabled = false
    navigator.hoverSelectionWhileKeyboardNavigating = footer.items.last?.id
    navigator.isKeyboardNavigating = false
    XCTAssertEqual(navigator.leadHistoryItem?.id, selected.id)
    XCTAssertEqual(navigator.selection.items.map(\.id), [selected.id])
    XCTAssertNil(footer.selectedItem)
  }
}
