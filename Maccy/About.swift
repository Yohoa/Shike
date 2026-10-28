import Cocoa

class About {
  /// Upstream attribution: the project this build is based on.
  private var upstream: NSAttributedString {
    NSAttributedString(string: NSLocalizedString("Based on Maccy 2.8.0", comment: "About base version"),
                       attributes: [.link: URL(string: "https://github.com/p0deje/Maccy")!])
  }

  private var credits: NSMutableAttributedString {
    let credits = NSMutableAttributedString(string: "",
                                            attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    credits.append(NSAttributedString(
      string: NSLocalizedString("Raphael local build", comment: "About build") + " · 2026-10-28\n"
        + NSLocalizedString("Memory fixes · Combined text and images", comment: "About features") + "\n\n",
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    ))
    credits.append(NSAttributedString(
      string: NSLocalizedString(Accessibility.allowed ? "Automatic paste: allowed" : "Automatic paste: needs Accessibility permission", comment: "Paste access status") + "\n\n",
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    ))
    credits.append(NSAttributedString(string: NSLocalizedString("Optional screenshot and image tools", comment: "About image tools") + "\n\n"))
    credits.append(NSAttributedString(string: NSLocalizedString("Optional notch clipboard shelf", comment: "About notch") + "\n\n"))
    credits.append(upstream)
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: NSLocalizedString("Maccy · Raphael’s build", comment: "About title"),
      .applicationVersion: "2.8.0 · " + String(format: NSLocalizedString("Local Fix %d", comment: "Local build version"), 11),
      .credits: credits
    ])
  }
}
