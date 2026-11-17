import Foundation

/// An incomplete acoustic pass, kept separately from accepted transcript evidence.
struct RecognitionDraft: Codable, Sendable, Equatable {
  var id: String
  var createdAt: String
  var segments: [Segment]
  var warnings: [String]
}
