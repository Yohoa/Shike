import AppKit

enum NotchPhase { case idle, peek, expanded }

/// All rects are in screen coordinates. The panel itself never resizes: it is fixed at
/// `panelFrame`, the shape springs between `shapeRect(_:)` inside it, and hit-testing only
/// accepts `hitRect(_:)`, so the transparent remainder never blocks the menu bar.
struct NotchLayout {
  var screenFrame: CGRect
  var safeTop: CGFloat
  var cutoutCenterX: CGFloat?
  var cutoutWidth: CGFloat
  var hasCutout: Bool { safeTop > 0 }
  var centerWidth: CGFloat { hasCutout ? max(120, cutoutWidth) : 44 }
  private var center: CGFloat { cutoutCenterX ?? screenFrame.midX }
  private static let panelMargin: CGFloat = 48
  /// Pointer slack before an open shelf counts as "left" (hysteresis).
  private static let grace: CGFloat = 12

  /// Concave shoulder radius at the top, then convex corner radius at the bottom.
  /// Idle has no shoulders, so on notched screens it never extends beyond the cutout.
  func radii(_ phase: NotchPhase) -> (top: CGFloat, bottom: CGFloat) {
    switch phase {
    case .idle: hasCutout ? (0, 8) : (0, 2.5)
    case .peek: (6, 12)
    case .expanded: (12, 26)
    }
  }

  /// Solid body size, excluding the shoulders.
  func bodySize(_ phase: NotchPhase) -> CGSize {
    switch phase {
    case .idle: hasCutout ? CGSize(width: centerWidth, height: safeTop) : CGSize(width: 44, height: 5)
    case .peek: hasCutout ? CGSize(width: centerWidth + 18, height: safeTop + 10) : CGSize(width: 96, height: 22)
    case .expanded:
      CGSize(width: min(520, max(100, screenFrame.width - 48)),
             height: min(390 + (hasCutout ? safeTop : 0), screenFrame.height - 24))
    }
  }

  func shapeRect(_ phase: NotchPhase) -> CGRect {
    let body = bodySize(phase)
    let width = body.width + 2 * radii(phase).top
    let x = min(max(screenFrame.minX, center - width / 2), screenFrame.maxX - width)
    return CGRect(x: x, y: screenFrame.maxY - body.height, width: width, height: body.height)
  }

  /// Where the pointer "feels" the notch: a stable zone a little larger than the cutout.
  var triggerRect: CGRect {
    let size = hasCutout ? CGSize(width: centerWidth + 44, height: safeTop + 14) : CGSize(width: 140, height: 26)
    let x = min(max(screenFrame.minX, center - size.width / 2), screenFrame.maxX - size.width)
    return CGRect(x: x, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
  }

  func hitRect(_ phase: NotchPhase) -> CGRect {
    switch phase {
    case .idle, .peek: triggerRect.union(shapeRect(.peek))
    case .expanded: shapeRect(.expanded)
    }
  }

  /// Hover region: like the hit rect, with a little grace around the open shelf.
  func hoverRect(_ phase: NotchPhase) -> CGRect {
    phase == .expanded ? hitRect(.expanded).insetBy(dx: -Self.grace, dy: -Self.grace) : hitRect(phase)
  }

  var panelFrame: CGRect {
    let expanded = shapeRect(.expanded)
    let width = min(screenFrame.width, expanded.width + 2 * Self.panelMargin)
    let height = min(screenFrame.height, expanded.height + Self.panelMargin)
    let x = min(max(screenFrame.minX, expanded.midX - width / 2), screenFrame.maxX - width)
    return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
  }

  init(frame: CGRect, safeTop: CGFloat, left: CGRect? = nil, right: CGRect? = nil) {
    screenFrame = frame
    self.safeTop = safeTop
    if safeTop > 0, let left, let right, right.minX > left.maxX {
      cutoutCenterX = (left.maxX + right.minX) / 2
      cutoutWidth = right.minX - left.maxX
    } else {
      cutoutCenterX = nil
      cutoutWidth = safeTop > 0 ? 180 : 0
    }
  }

  init(screen: NSScreen) {
    self.init(frame: screen.frame, safeTop: screen.safeAreaInsets.top,
              left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
  }
}

struct NotchBattery: Equatable {
  var percent: Int
  var charging: Bool
  var onAC: Bool

  init?(current: Int?, maximum: Int?, charging: Bool, onAC: Bool) {
    guard let current, let maximum, maximum > 0 else { return nil }
    percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
    self.charging = charging
    self.onAC = onAC
  }
}
