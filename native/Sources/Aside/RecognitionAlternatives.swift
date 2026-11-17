import Foundation

/// Independent machine hearings, never extra speakers or a second copy of truth.
/// IDs bind an alternative to canonical passages from the same capture source.
struct RecognitionAlternativeWord: Codable, Sendable, Equatable {
  var text: String
  var start: Double
  var end: Double
}
struct RecognitionAlternative: Codable, Sendable, Equatable {
  var id: String
  var model: String
  var sourceIDs: [String]
  var start: Double
  var end: Double
  var text: String
  var words: [RecognitionAlternativeWord]
  var speaker: String? = nil
}
