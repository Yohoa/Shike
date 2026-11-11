import CryptoKit
import Foundation
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  /// Large values (images) live in files beside the store, so items can be listed without reading them.
  @Attribute(.externalStorage) var value: Data?
  /// SHA-256 of `value` ("" for no value); nil only for rows stored before 2.8.28 that are not migrated yet.
  var digest: String?

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil) {
    self.type = type
    self.value = value
    self.digest = Self.digest(of: value)
  }

  /// Set the value and keep its digest in step.
  func setValue(_ newValue: Data?) {
    value = newValue
    digest = Self.digest(of: newValue)
  }

  nonisolated static func digest(of data: Data?) -> String {
    guard let data else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Same type and same data, compared by digest when both have one so neither value is read.
  func matches(_ other: HistoryItemContent) -> Bool {
    guard type == other.type else { return false }
    if let digest, let otherDigest = other.digest { return digest == otherDigest }
    return value == other.value
  }
}
