import AppKit

struct Accessibility {
  // Pasting posts keyboard events; it does not inspect other apps' AX trees.
  // AXIsProcessTrusted can be false in a sandbox despite PostEvent consent.
  static var allowed: Bool { CGPreflightPostEventAccess() }

  @discardableResult
  static func check() -> Bool {
    allowed || CGRequestPostEventAccess()
  }
}
