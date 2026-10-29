import AppKit
import CryptoKit
import Security
import SwiftUI

// Updates from the public GitHub releases of Yohoa/Shike, the way Kestrel does it, within the App Sandbox:
// once a day at launch (Settings → General) and on request. Installing downloads the release's DMG into
// ~/Downloads, checks it against the SHA-256 in the release notes and checks that the disk image is signed with
// the same certificate as this app, then opens it and quits so the new Shike can be dragged over the old one.
// The sandbox does not let the app replace itself, so that last step is the person's.
@MainActor
@Observable
final class Updater {
  static let shared = Updater()
  static let repo = "Yohoa/Shike"

  struct Release: Equatable {
    let version: String          // "2.8.13"
    let notes: String
    let dmg: URL
    let name: String             // "Shike-2.8.13.dmg"
    let page: URL

    /// "SHA-256 of `Shike-2.8.13.dmg`: `…`" in the notes.
    var sha256: String? { Updater.sha256(in: notes) }
  }

  enum Phase: Equatable {
    case idle, checking, available(Release), upToDate, downloading(Double), opened, failed(String)
  }

  var phase: Phase = .idle
  var autoCheck = UserDefaults.standard.object(forKey: "localUpdatesAutoCheck") as? Bool ?? true {
    didSet { UserDefaults.standard.set(autoCheck, forKey: "localUpdatesAutoCheck") }
  }

  private var window: NSWindow?
  private var task: URLSessionDownloadTask?
  private var progressWatch: NSKeyValueObservation?

  nonisolated static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  /// "2.8.13" is newer than "2.8.9". Only plain dotted numbers count as versions.
  nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
      let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
      if p != q { return p > q }
    }
    return false
  }

  nonisolated static func sha256(in notes: String) -> String? {
    guard let r = notes.range(of: "SHA-256[^`]*`[^`]+`: `([0-9a-f]{64})`", options: .regularExpression) else { return nil }
    return String(notes[r]).components(separatedBy: "`").dropLast().last
  }

  /// A `releases/latest` answer from the GitHub API. Tags that aren't a plain version (the old
  /// "v2.8.0-shike.12" ones) are not offered as updates.
  nonisolated static func parse(_ data: Data) -> Release? {
    guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
          let assets = j["assets"] as? [[String: Any]],
          let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
          let name = dmg["name"] as? String,
          let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    guard version.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil else { return nil }
    return Release(version: version, notes: j["body"] as? String ?? "", dmg: url, name: name, page: page)
  }

  /// At launch: at most once a day, and quietly (only a newer version is shown).
  func checkAtLaunch() {
    guard autoCheck else { return }
    if let last = UserDefaults.standard.object(forKey: "localUpdatesLastCheck") as? Date,
       Date().timeIntervalSince(last) < 20 * 3600 { return }
    check(userAsked: false)
  }

  func check(userAsked: Bool) {
    if case .downloading = phase { return }
    phase = .checking
    if userAsked { showWindow() }
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalCacheData  // a cached answer can hide a release published minutes ago
    Task {
      let result = try? await URLSession.shared.data(for: request)
      UserDefaults.standard.set(Date(), forKey: "localUpdatesLastCheck")
      let code = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
      guard let data = result?.0, code == 200, let release = Self.parse(data) else {
        phase = userAsked ? .failed(code == 0 ? tr("Couldn't reach GitHub.")
                                              : String(format: tr("GitHub answered %d."), code)) : .idle
        return
      }
      let skipped = UserDefaults.standard.string(forKey: "localUpdatesSkipped")
      if Self.isNewer(release.version, than: Self.currentVersion), userAsked || skipped != release.version {
        phase = .available(release)
        showWindow()
      } else {
        phase = userAsked ? .upToDate : .idle
      }
    }
  }

  func skip(_ release: Release) {
    UserDefaults.standard.set(release.version, forKey: "localUpdatesSkipped")
    close()
  }

  func install(_ release: Release) {
    guard let expected = release.sha256 else {
      phase = .failed(tr("The release has no checksum, so it was not downloaded."))
      return
    }
    phase = .downloading(0)
    let downloadTask = URLSession.shared.downloadTask(with: release.dmg) { file, _, error in
      // The temporary file is gone once this returns: check and move it now.
      let result = Self.verifyAndKeep(file, name: release.name, expectedSHA: expected, error: error)
      Task { @MainActor in self.finishDownload(result) }
    }
    progressWatch = downloadTask.progress.observe(\.fractionCompleted) { progress, _ in
      let fraction = progress.fractionCompleted
      Task { @MainActor in if case .downloading = self.phase { self.phase = .downloading(fraction) } }
    }
    task = downloadTask
    downloadTask.resume()
  }

  func cancel() {
    task?.cancel()
    task = nil
    progressWatch = nil
    close()
  }

  private func finishDownload(_ result: Result<URL, UpdateError>) {
    progressWatch = nil
    task = nil
    switch result {
    case .failure(let error):
      phase = .failed(error.message)
    case .success(let dmg):
      phase = .opened
      NSWorkspace.shared.open(dmg)
      // Finder can't replace an app that is running.
      Task {
        try? await Task.sleep(for: .seconds(4))
        NSApp.terminate(nil)
      }
    }
  }

  struct UpdateError: Error { let message: String }

  /// Checks the downloaded disk image (checksum and signer) and moves it to ~/Downloads.
  nonisolated static func verifyAndKeep(_ file: URL?, name: String, expectedSHA: String,
                                        error: Error?) -> Result<URL, UpdateError> {
    guard let file, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
      return .failure(.init(message: tr("The download failed.") + (error.map { " " + $0.localizedDescription } ?? "")))
    }
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard sha == expectedSHA else {
      return .failure(.init(message: tr("The download doesn't match the release's checksum, so it was not opened.")))
    }
    guard let mine = signingCertificate(of: Bundle.main.bundleURL), signingCertificate(of: file) == mine else {
      return .failure(.init(message: tr("The disk image isn't signed like this copy of Shike, so it was not opened.")))
    }
    // In the sandbox this is a link from the container to the real ~/Downloads (downloads entitlement); open the
    // real path, since Finder's disk image mounter is not allowed into another app's container.
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
    var dest = downloads.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: dest.path) {
      dest = downloads.appendingPathComponent("\((name as NSString).deletingPathExtension)-\(Int(Date().timeIntervalSince1970)).dmg")
    }
    do { try FileManager.default.moveItem(at: file, to: dest) } catch {
      return .failure(.init(message: tr("The download could not be saved to Downloads.")))
    }
    return .success(dest)
  }

  /// The leaf certificate of a validly signed app or disk image (a self-signed one is compared as is).
  nonisolated static func signingCertificate(of url: URL) -> Data? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let certificate = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
    return SecCertificateCopyData(certificate) as Data
  }

  nonisolated static func tr(_ key: String) -> String { NSLocalizedString(key, comment: "Updates") }
  private func tr(_ key: String) -> String { Self.tr(key) }

  // MARK: window

  func showWindow() {
    if window == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = tr("Software Update")
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: UpdateView(updater: self))
      window.center()
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func close() {
    if case .downloading = phase { task?.cancel() }
    if case .opened = phase {} else { phase = .idle }
    window?.close()
    window = nil
  }

  /// The release notes without the install paragraph and the checksum line, Markdown markers stripped.
  nonisolated static func whatsNew(_ notes: String) -> String {
    var lines: [String] = []
    for line in notes.components(separatedBy: "\n") {
      if line.hasPrefix("**Install") { break }
      if line.hasPrefix("SHA-256") { continue }
      lines.append(line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""))
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct UpdateView: View {
  var updater: Updater

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          Text(String(format: NSLocalizedString("You have %@.", comment: "Updates"), Updater.currentVersion))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      switch updater.phase {
      case .available(let release):
        ScrollView {
          Text(Updater.whatsNew(release.notes)).font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(height: 200)
        Text("Shike downloads it to Downloads, checks it and opens it, then quits. Drag Shike onto Applications and choose Replace.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Skip This Version") { updater.skip(release) }.fixedSize()
          Button("Release Page") { NSWorkspace.shared.open(release.page) }.fixedSize()
          Spacer()
          Button("Later") { updater.close() }.fixedSize()
          Button("Download and Open") { updater.install(release) }.keyboardShortcut(.defaultAction).fixedSize()
        }
      case .downloading(let fraction):
        ProgressView(value: fraction) { Text("Downloading…").font(.caption) }
        HStack { Spacer(); Button("Cancel") { updater.cancel() } }
      case .opened:
        Text("The new version is open in Finder. Drag Shike onto Applications, choose Replace, then open Shike again. Shike quits now.")
          .fixedSize(horizontal: false, vertical: true)
      case .checking:
        ProgressView().controlSize(.small)
      case .upToDate:
        Text("You're using the newest version.")
        HStack { Spacer(); Button("OK") { updater.close() }.keyboardShortcut(.defaultAction) }
      case .failed(let why):
        Text(why).fixedSize(horizontal: false, vertical: true)
        HStack { Spacer(); Button("OK") { updater.close() }.keyboardShortcut(.defaultAction) }
      case .idle:
        HStack { Spacer(); Button("Close") { updater.close() } }
      }
    }
    .padding(20)
    .frame(width: 560)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var title: String {
    switch updater.phase {
    case .available(let release): String(format: NSLocalizedString("Shike %@ is available", comment: "Updates"), release.version)
    case .downloading, .opened: NSLocalizedString("Updating Shike", comment: "Updates")
    case .checking: NSLocalizedString("Checking for updates…", comment: "Updates")
    case .upToDate: NSLocalizedString("Shike is up to date", comment: "Updates")
    default: NSLocalizedString("Software Update", comment: "Updates")
    }
  }
}
