import AppKit
import OSLog

/// Shike lives in the menu bar and has to stay up, but macOS's App Intents service (`linkd`) takes over an
/// already-running Shike when something uses its Shortcuts actions and asks for it to quit once the action is
/// idle. This lets only deliberate quits through: our own Quit, the updater, logout / restart / shutdown, and
/// a quit sent by an app or script the person is using (Activity Monitor, `osascript`). Anything else is
/// refused and logged under `studio.yohoa.Shike` / `lifecycle`.
@MainActor
final class TerminationGuard {
  static let shared = TerminationGuard()
  nonisolated static let log = Logger(subsystem: "studio.yohoa.Shike", category: "lifecycle")

  nonisolated enum Sender: Equatable {
    case application, script, system(String), unknown
  }

  private var explicit = false

  func start() {
    // Never opt in to being quit when idle.
    ProcessInfo.processInfo.disableAutomaticTermination("Shike keeps the clipboard history running")
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { self.explicit = true } }
  }

  /// Our own Quit button, the updater.
  func quit() {
    explicit = true
    NSApp.terminate(nil)
  }

  func reply() -> NSApplication.TerminateReply {
    if AppDelegate.isTesting { return .terminateNow }
    let event = NSAppleEventManager.shared().currentAppleEvent
    let sender = Self.sender(of: event)
    let reason = Self.quitReason(of: event)
    let allowed = Self.allows(explicit: explicit, reason: reason, sender: sender)
    Self.log.info("quit request from \(String(describing: sender), privacy: .public), reason \(reason ?? "-", privacy: .public): \(allowed ? "allowed" : "refused", privacy: .public)")
    return allowed ? .terminateNow : .terminateCancel
  }

  nonisolated static let powerOffReasons: Set<String> = ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"]

  nonisolated static func allows(explicit: Bool, reason: String?, sender: Sender) -> Bool {
    if explicit { return true }
    if let reason, powerOffReasons.contains(reason) { return true }
    return sender == .application || sender == .script
  }

  nonisolated static func sender(of event: NSAppleEventDescriptor?) -> Sender {
    guard let pid = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 else { return .unknown }
    if let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil, app.activationPolicy != .prohibited {
      return .application
    }
    var buffer = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buffer, UInt32(buffer.count))
    let name = String(cString: buffer)
    return name == "osascript" ? .script : .system(name.isEmpty ? "pid \(pid)" : name)
  }

  nonisolated static func quitReason(of event: NSAppleEventDescriptor?) -> String? {
    guard let code = event?.attributeDescriptor(forKeyword: 0x7768_793F)?.enumCodeValue, code != 0 else { return nil }  // 'why?'
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    return String(bytes: bytes, encoding: .macOSRoman)
  }
}
