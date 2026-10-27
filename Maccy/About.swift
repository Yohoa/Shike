import Cocoa

class About {
  private let familyCredits = NSAttributedString(
    string: "Special thank you to Tonia, Anna & Guy! ❤️",
    attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
  )

  private var kossCredits: NSMutableAttributedString {
    let string = NSMutableAttributedString(string: "Kudos to Sasha Koss for help! 🏂",
                                           attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    string.addAttribute(.link, value: "https://koss.nocorp.me", range: NSRange(location: 9, length: 10))
    return string
  }

  private var links: NSMutableAttributedString {
    let string = NSMutableAttributedString(string: "Website│GitHub│Support",
                                           attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    string.addAttribute(.link, value: "https://maccy.app", range: NSRange(location: 0, length: 7))
    string.addAttribute(.link, value: "https://github.com/p0deje/Maccy", range: NSRange(location: 8, length: 6))
    string.addAttribute(.link, value: "mailto:support@maccy.app", range: NSRange(location: 15, length: 7))
    return string
  }

  private var credits: NSMutableAttributedString {
    let credits = NSMutableAttributedString(string: "",
                                            attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    credits.append(NSAttributedString(
      string: NSLocalizedString("Raphael local build", comment: "About build") + " · 2026-10-27\n"
        + NSLocalizedString("Memory fixes · Combined text and images", comment: "About features") + "\n"
        + NSLocalizedString("Based on Maccy 2.8.0", comment: "About base version") + "\n\n",
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    ))
    credits.append(NSAttributedString(
      string: NSLocalizedString(Accessibility.allowed ? "Automatic paste: allowed" : "Automatic paste: needs Accessibility permission", comment: "Paste access status") + "\n\n",
      attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
    ))
    credits.append(NSAttributedString(string: NSLocalizedString("Optional screenshot and image tools", comment: "About image tools") + "\n\n"))
    credits.append(NSAttributedString(string: NSLocalizedString("Optional notch clipboard shelf", comment: "About notch") + "\n\n"))
    credits.append(links)
    credits.append(NSAttributedString(string: "\n\n"))
    credits.append(kossCredits)
    credits.append(NSAttributedString(string: "\n"))
    credits.append(familyCredits)
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: NSLocalizedString("Maccy · Raphael’s build", comment: "About title"),
      .applicationVersion: "2.8.0 · " + String(format: NSLocalizedString("Local Fix %d", comment: "Local build version"), 10),
      .credits: credits
    ])
  }
}
