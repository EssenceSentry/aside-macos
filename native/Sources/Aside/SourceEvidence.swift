import Foundation

/// Resolves citations and passage locators against current or retained transcript versions.
struct TranscriptEvidence: Codable, Sendable {
  var meetingID: String
  var title: String
  var location: String
  var excerpt: String
  var text: String
  var rawText: String?
  var current: Bool
  var revision: String

  static func resolve(_ source: Source, in meeting: Meeting) throws -> TranscriptEvidence {
    guard source.meetingID == meeting.id else {
      throw AsideError("That source belongs to a different meeting.")
    }
    func matches(_ text: String) -> Bool { source.excerpt.isEmpty || text.contains(source.excerpt) }
    func evidence(_ text: String, raw: String? = nil, current: Bool, label: String)
      -> TranscriptEvidence
    {
      TranscriptEvidence(
        meetingID: meeting.id, title: source.title, location: source.location,
        excerpt: source.excerpt, text: text, rawText: raw, current: current, revision: label)
    }
    func versions(_ segment: Segment) -> [(Int, String)] {
      var values = [(segment.revision, segment.text)]
      for correction in segment.corrections {
        if let before = correction.beforeRevision { values.append((before, correction.before)) }
        if let after = correction.afterRevision { values.append((after, correction.after)) }
      }
      // Legacy corrections have no explicit revision fields. Infer only a complete, intact chain.
      if segment.revision == segment.corrections.count,
        let first = segment.corrections.first, first.before == segment.rawText,
        segment.corrections.last?.after == segment.text,
        zip(segment.corrections, segment.corrections.dropFirst()).allSatisfy({
          $0.after == $1.before
        })
      {
        values.append((0, segment.rawText))
        values.append(
          contentsOf: segment.corrections.enumerated().map { ($0.offset + 1, $0.element.after) })
      }
      return values
    }
    if source.documentID == "meeting:" + meeting.id, let id = source.segmentID {
      let current = meeting.segments.first(where: { $0.id == id })
      let archived = (meeting.recognitionHistory ?? []).reversed().flatMap { snapshot in
        snapshot.segments.filter { $0.id == id }.map {
          ($0, "Earlier recognition · " + snapshot.createdAt)
        }
      }
      if let requested = source.segmentRevision {
        if let segment = current, requested == segment.revision, matches(segment.text) {
          let active = sourceIsCurrent(source, in: meeting)
          return evidence(
            segment.text, raw: segment.rawText, current: active,
            label: active ? "Current recognition" : "Recognition superseded by your document edit")
        }
        for (segment, label) in (current.map { [($0, "Earlier passage revision")] } ?? [])
          + archived
        {
          if let version = versions(segment).first(where: { $0.0 == requested && matches($0.1) }) {
            return evidence(
              version.1, raw: segment.rawText, current: false,
              label: label + " · revision \(requested)")
          }
        }
      } else {
        // A locator without a quotation navigates to the current passage. It
        // does not pretend the model supplied or verified quoted words.
        if source.excerpt.isEmpty, let segment = current ?? archived.first?.0 {
          let superseded =
            meeting.document.map {
              $0.author == "user" && manualCoveredSegmentIDs($0).contains(segment.id)
            } ?? false
          let active = current != nil && !superseded
          return evidence(
            segment.text, raw: segment.rawText, current: active,
            label: active
              ? "Referenced passage · current version" : "Referenced earlier recognition")
        }
        // A legacy fragment may survive a changed negation or number elsewhere in the passage.
        let segments = (current.map { [$0] } ?? []) + archived.map(\.0)
        var candidates = Set<String>()
        for segment in segments {
          candidates.formUnion(
            ([segment.text, segment.rawText]
              + segment.corrections.flatMap { [$0.before, $0.after] }).filter(matches))
        }
        if !candidates.isEmpty {
          let active = current != nil && sourceIsCurrent(source, in: meeting)
          return evidence(
            candidates.count == 1 ? candidates.first! : source.excerpt, current: active,
            label: active ? "Current recognition" : "Saved quotation · passage version unverified")
        }
      }
    } else if source.documentID == "meeting-document:" + meeting.id,
      let revision = source.documentRevision
    {
      func context(_ text: String) -> String {
        if source.excerpt.isEmpty { return text }
        let paragraph = text.components(separatedBy: "\n\n").first(where: matches) ?? text
        guard paragraph.count > 6000 else { return paragraph }
        guard let range = paragraph.range(of: source.excerpt) else { return source.excerpt }
        let start =
          paragraph.index(range.lowerBound, offsetBy: -1500, limitedBy: paragraph.startIndex)
          ?? paragraph.startIndex
        let end =
          paragraph.index(range.upperBound, offsetBy: 1500, limitedBy: paragraph.endIndex)
          ?? paragraph.endIndex
        return String(paragraph[start..<end])
      }
      if let document = meeting.document, document.revision == revision, matches(document.text) {
        return evidence(
          context(document.text), current: true, label: "Current document · revision \(revision)")
      }
      if let document = meeting.documentHistory?.last(where: {
        $0.revision == revision && matches($0.text)
      }) {
        return evidence(
          context(document.text), current: false, label: "Earlier document · revision \(revision)")
      }
    }
    throw AsideError(
      "The referenced passage or version is not available in this transcript or its retained history."
    )
  }
}

extension AppController {
  func transcriptEvidence(for source: Source) throws -> TranscriptEvidence {
    guard let meeting = state.meeting else {
      throw AsideError("Choose the citation's meeting first.")
    }
    return try TranscriptEvidence.resolve(source, in: meeting)
  }
}
