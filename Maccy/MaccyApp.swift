import SwiftUI

@main
struct MaccyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  // It's impossible to create sceneless application,
  // so we are hacking this around by creating a menubar
  // scene that is always hidden.
  @State private var hiddenMenu: Bool = false

  init() {
    if CommandLine.arguments.contains("--local-paste-diagnostics") {
      let values: [String: Any] = ["accessibility": AXIsProcessTrusted(), "postEvents": CGPreflightPostEventAccess()]
      let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let data = try? JSONSerialization.data(withJSONObject: values) {
        try? data.write(to: directory.appendingPathComponent("local-paste-diagnostics.json"), options: .atomic)
      }
      exit(0)
    }
  }

  var body: some Scene {
    MenuBarExtra("", isInserted: $hiddenMenu) {
      EmptyView()
    }
  }
}
