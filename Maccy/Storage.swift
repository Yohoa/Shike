import AppKit.NSPasteboard
import Foundation
import OSLog
import SQLite3
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size + Self.directorySize(externalDataURL))
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")
  private var externalDataURL: URL { url.deletingLastPathComponent().appending(path: ".Storage_SUPPORT/_EXTERNAL_DATA") }

  nonisolated static let log = Logger(subsystem: "studio.yohoa.Shike", category: "storage")
  /// Set once the store was copied before its first launch with external storage.
  private static let backedUpKey = "localStoreBackedUp"
  private static let vacuumKey = "localStoreNeedsVacuum"
  private static let backupSuffix = "-backup-before-2.8.28"
  private var externalizing: Task<Void, Never>?

  init() {
    var config = ModelConfiguration(url: url)
    if !AppDelegate.isTesting {
      Self.backUpBeforeExternalizing(url)
      Self.vacuumIfNeeded(url)
    }

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
    if !AppDelegate.isTesting {
      let pending = (try? ModelContext(container).fetchCount(
        FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.digest == nil }))) ?? -1
      let all = (try? ModelContext(container).fetchCount(FetchDescriptor<HistoryItemContent>())) ?? -1
      let sqlite = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
      let externalFiles = (try? FileManager.default.contentsOfDirectory(atPath: externalDataURL.path).count) ?? -1
      Self.log.notice("Store: \(all) contents, \(pending) without digest, SQLite \(sqlite) B, \(externalFiles) external files, \(Self.directorySize(self.externalDataURL)) B external")
    }
  }

  // MARK: - Large values out of memory (2.8.28)

  /// Copy the store once before the first launch that moves its data, so it can be restored by hand.
  private static func backUpBeforeExternalizing(_ url: URL) {
    let files = FileManager.default
    guard !UserDefaults.standard.bool(forKey: backedUpKey), files.fileExists(atPath: url.path) else { return }
    let base = url.deletingPathExtension().lastPathComponent
    for suffix in ["", "-wal", "-shm"] {
      let source = url.deletingLastPathComponent().appending(path: base + ".sqlite" + suffix)
      let target = url.deletingLastPathComponent().appending(path: base + backupSuffix + ".sqlite" + suffix)
      guard files.fileExists(atPath: source.path), !files.fileExists(atPath: target.path) else { continue }
      do { try files.copyItem(at: source, to: target) } catch { log.error("Backup failed: \(error)"); return }
    }
    UserDefaults.standard.set(true, forKey: backedUpKey)
    log.notice("Backed up the store before moving large values out of it")
  }

  /// Moving values out of SQLite leaves its pages free; give that space back once, before the store opens.
  private static func vacuumIfNeeded(_ url: URL) {
    guard UserDefaults.standard.bool(forKey: vacuumKey) else { return }
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open(url.path, &db) == SQLITE_OK, sqlite3_exec(db, "VACUUM", nil, nil, nil) == SQLITE_OK else {
      log.error("VACUUM failed")
      return
    }
    UserDefaults.standard.set(false, forKey: vacuumKey)
    log.notice("VACUUM done")
  }

  private static func directorySize(_ url: URL) -> Int64 {
    guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
      .reduce(0) { $0 + Int64($1) }
  }

  /// Once per store: give every value a digest and rewrite large values so they move to external files.
  /// Runs before the history is loaded, so no item in the main context points at a replaced row.
  func externalizeIfNeeded() async {
    if externalizing == nil {
      guard Self.pendingCount(in: container) > 0 else { return }
      let container = self.container
      externalizing = Task.detached(priority: .userInitiated) { Self.externalize(in: container) }
    }
    await externalizing?.value
    externalizing = nil
    if Self.pendingCount(in: container) == 0, !AppDelegate.isTesting {
      UserDefaults.standard.set(true, forKey: Self.vacuumKey)
    }
  }

  nonisolated static func pendingCount(in container: ModelContainer) -> Int {
    (try? ModelContext(container).fetchCount(
      FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.digest == nil }))) ?? 0
  }

  nonisolated static func externalize(in container: ModelContainer, inlineLimit: Int = 100_000) {
    log.notice("Externalizing store")
    do {
      let ids = try ModelContext(container).fetchIdentifiers(
        FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.digest == nil }))
      var moved = 0
      for start in stride(from: 0, to: ids.count, by: 16) {
        try autoreleasepool {
          let context = ModelContext(container)
          context.autosaveEnabled = false
          let batch = ids[start..<min(start + 16, ids.count)]
          for content in batch.compactMap({ context.model(for: $0) as? HistoryItemContent }) {
            guard let value = content.value, value.count > inlineLimit else {
              content.digest = HistoryItemContent.digest(of: content.value)
              continue
            }
            // A new row is written with external storage; swap it in and drop the inline one in one save.
            let copy = HistoryItemContent(type: content.type, value: value)
            context.insert(copy)
            copy.item = content.item
            context.delete(content)
            moved += 1
          }
          try context.save()
        }
      }
      log.notice("Externalized store: \(ids.count) contents, \(moved) moved out of SQLite")
    } catch {
      log.error("Externalizing failed: \(String(reflecting: error))")
    }
  }

  /// Read a stored value through a throwaway context, so the caller's objects never keep it in memory.
  /// Falls back to nil for rows that are not saved yet.
  nonisolated static func detachedValue(of content: HistoryItemContent, in container: ModelContainer) -> Data? {
    let id = content.persistentModelID
    let context = ModelContext(container)
    return (try? context.fetch(FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.persistentModelID == id })))?
      .first?.value
  }

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  func removeUnpersistableContents() throws -> Int {
    let contents = try context.fetch(FetchDescriptor<HistoryItemContent>())
    let unwanted = contents.filter {
      !Clipboard.shared.isPersistable(NSPasteboard.PasteboardType($0.type))
    }

    guard !unwanted.isEmpty else {
      return 0
    }

    unwanted.forEach(context.delete)
    context.processPendingChanges()
    try context.save()

    return unwanted.count
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }
}
