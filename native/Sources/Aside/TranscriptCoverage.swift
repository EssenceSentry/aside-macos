import Foundation

/// A saved user document covers stable passage identities even if a passage is edited later.
/// IDs can contain colons; only the final colon separates the revision.
func manualCoveredSegmentIDs(_ document: ReadableDocument) -> Set<String> {
  guard document.author == "user" else { return [] }
  return Set(
    document.sourceFingerprint.split(separator: "|").compactMap { entry in
      guard let colon = entry.lastIndex(of: ":"),
        Int(entry[entry.index(after: colon)...]) != nil
      else { return nil }
      return String(entry[..<colon])
    })
}
