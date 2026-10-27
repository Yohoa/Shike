import Observation
import Foundation
@Observable final class Item { var title = "hello" }
final class Decorator {
  let item: Item
  let weakCapture: Bool
  init(_ item: Item, weakCapture: Bool) {
    self.item = item
    self.weakCapture = weakCapture
    if weakCapture {
      withObservationTracking { _ = item.title } onChange: { [weak self] in self?.changed() }
    } else {
      withObservationTracking { _ = item.title } onChange: { self.changed() }
    }
  }
  func changed() {}
}
func check(_ weakCapture: Bool) {
  weak var observed: Decorator?
  do {
    let item = Item()
    let decorator = Decorator(item, weakCapture: weakCapture)
    observed = decorator
  }
  print("\(weakCapture ? "weak" : "strong") capture: object released = \(observed == nil)")
}
check(false)
check(true)
