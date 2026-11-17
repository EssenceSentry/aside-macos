import Foundation

/// Owned by the speech actor. Every suspended operation keeps its generation
/// alive; retirement is permitted only between operations. The owner detaches
/// all cached objects before its first retirement await, so new work can lazily
/// acquire a fresh generation while cleanup finishes on the old one.
struct AcousticModelOwnership {
  private var uses: Set<UUID> = []
  private var retirement: UUID?

  mutating func beginUse() -> UUID {
    let id = UUID()
    uses.insert(id)
    return id
  }

  mutating func endUse(_ id: UUID) { uses.remove(id) }

  mutating func beginRetirement() -> UUID? {
    guard uses.isEmpty, retirement == nil else { return nil }
    let id = UUID()
    retirement = id
    return id
  }

  mutating func endRetirement(_ id: UUID) {
    if retirement == id { retirement = nil }
  }
}
