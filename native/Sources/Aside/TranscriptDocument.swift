import Foundation

struct ReadableBlock: Codable, Sendable, Equatable {
  var id: String
  var speaker: String
  var sourceIDs: [String]
  var text: String
  var needsReview: Bool = false
}
struct ReadableDocument: Codable, Sendable, Equatable {
  var suggestedTitle: String? = nil
  var speakerNames: [String: String]? = nil
  var blocks: [ReadableBlock]? = nil
  var reviewNotes: [String]? = nil
  var text: String
  var sourceFingerprint: String
  var revision: Int
  var createdAt: String
  var author: String
}
struct RecognitionSnapshot: Codable, Sendable, Equatable {
  var id: String
  var createdAt: String
  var technique: String
  var segments: [Segment]
  var speakerNames: [String: String]? = nil
  var alternatives: [RecognitionAlternative]? = nil
}
struct DocumentPolishError: LocalizedError, Sendable {
  let draft: ReadableDocument
  var errorDescription: String? {
    "The language service could not finish. The original text is available; try polishing again."
  }
}
func transcriptFingerprint(_ segments: [Segment]) -> String {
  segments.map { "\($0.id):\($0.revision)" }.joined(separator: "|")
}
enum TranscriptDocument {
  static func nextRevision(_ meeting: Meeting) -> Int {
    max(meeting.document?.revision ?? 0, meeting.documentHistory?.map(\.revision).max() ?? 0) + 1
  }
  static func removeFillers(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"\b(?:u+m+|u+h+|e+r+m+|e+h+m+|e+m+m+|h+m+m+)\b[\s,]*"#,
      with: " ", options: [.regularExpression, .caseInsensitive]
    )
    .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  /// Name edits apply to prose as well as labels. The document records the names
  /// its prose already uses, so repeated renames and swaps are applied once.
  static func nameReplacements(_ meeting: Meeting, previousNames: [String: String] = [:])
    -> [String: String]
  {
    let speakers = Self.speakers(meeting.segments).union(
      meeting.document?.blocks?.map(\.speaker) ?? [])
    var replacements: [String: String] = [:]
    for speaker in speakers {
      let original = speaker.replacingOccurrences(
        of: #"^(?:Imported audio|Microphone|System audio) · "#, with: "",
        options: .regularExpression)
      let previous = previousNames[speaker] ?? original
      let current = meeting.speakerNames?[speaker] ?? original
      guard previous != current, !previous.isEmpty,
        previous.range(
          of:
            #"^(?:you|speaker\s*\d+|unknown(?: speaker)?|mixed speakers|microphone|system audio|note)$"#,
          options: [.regularExpression, .caseInsensitive]) == nil,
        !previous.contains(" + ")
      else { continue }
      replacements[previous] = current
    }
    return replacements
  }
  static func replacingNames(_ text: String, replacements: [String: String]) -> String {
    guard !replacements.isEmpty else { return text }
    let alternatives = replacements.keys.sorted { $0.count > $1.count }.map(
      NSRegularExpression.escapedPattern(for:)
    ).joined(separator: "|")
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])(?:"# + alternatives + #")(?![\p{L}\p{N}_])"#)
    else { return text }
    let original = text as NSString
    let result = NSMutableString(string: text)
    for match in expression.matches(in: text, range: NSRange(location: 0, length: original.length))
      .reversed()
    {
      if let replacement = replacements[original.substring(with: match.range)] {
        result.replaceCharacters(in: match.range, with: replacement)
      }
    }
    return result as String
  }
  static func refreshSpeakerNames(_ meeting: inout Meeting) {
    guard var document = meeting.document,
      !(meeting.speakerNames ?? [:]).isEmpty || !(document.speakerNames ?? [:]).isEmpty
    else { return }
    guard document.speakerNames != (meeting.speakerNames ?? [:]) else { return }
    let previous = document
    let replacements = nameReplacements(meeting, previousNames: document.speakerNames ?? [:])
    document.text = replacingNames(document.text, replacements: replacements)
    document.blocks = document.blocks?.map { block in
      var block = block
      block.text = replacingNames(block.text, replacements: replacements)
      return block
    }
    document.speakerNames = meeting.speakerNames ?? [:]
    if document.text != previous.text || document.blocks != previous.blocks {
      meeting.documentHistory = (meeting.documentHistory ?? []) + [previous]
      document.revision = nextRevision(meeting)
      document.createdAt = timestamp()
    }
    meeting.document = document
  }
  static func plain(_ meeting: Meeting, raw: Bool = false) -> String {
    var paragraphs: [String] = []
    var start = 0
    var covered = Set<String>()
    if !raw, let document = meeting.document {
      let prefix =
        document.sourceFingerprint.isEmpty
        ? [] : document.sourceFingerprint.components(separatedBy: "|")
      if document.author == "user"
        || (prefix.count <= meeting.segments.count
          && document.sourceFingerprint
            == transcriptFingerprint(Array(meeting.segments.prefix(prefix.count))))
      {
        if document.author != "user", let blocks = document.blocks, !blocks.isEmpty {
          paragraphs = rendered(blocks, meeting: meeting)
        } else {
          paragraphs = document.text.components(separatedBy: "\n\n")
        }
        if document.author == "user" {
          covered = manualCoveredSegmentIDs(document)
        } else {
          start = prefix.count
        }
      }
    }
    let labelSpeakers = shouldLabelSpeakers(meeting)
    var previous: Segment?
    for segment in meeting.segments.dropFirst(start).flatMap({ speakerRuns($0, raw: raw) }) {
      if covered.contains(segment.id) { continue }
      let text =
        raw
        ? segment.rawText
        : replacingNames(removeFillers(segment.text), replacements: nameReplacements(meeting))
      guard !text.isEmpty else { continue }
      if paragraphs.isEmpty || previous == nil || previous?.speaker != segment.speaker
        || segment.start - (previous?.end ?? segment.start) > 8
        || ((paragraphs.last?.count ?? 0) > 650
          && [".", "?", "!"].contains(String(paragraphs.last?.last ?? " ")))
      {
        paragraphs.append(
          labelSpeakers ? speakerLabel(segment.speaker, meeting: meeting) + text : text)
      } else {
        paragraphs[paragraphs.count - 1] += " " + text
      }
      previous = segment
    }
    return paragraphs.joined(separator: "\n\n")
  }
  private static func speakerLabel(_ speaker: String, meeting: Meeting) -> String {
    let alias = meeting.speakerNames?[speaker]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = (alias?.isEmpty == false ? alias! : speaker)
      .replacingOccurrences(
        of: #"^(?:Imported audio|Microphone|System audio) · "#, with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "" : name + ": "
  }
  /// Include voices visible in either current prose or original measured runs.
  static func speakers(_ segments: [Segment]) -> Set<String> {
    Set(
      segments.flatMap { speakerRuns($0) + speakerRuns($0, raw: true) }
        .map(\.speaker).filter { !$0.isEmpty })
  }
  private static func shouldLabelSpeakers(_ meeting: Meeting) -> Bool {
    let speakers = Self.speakers(meeting.segments)
      .union(meeting.document?.blocks?.map(\.speaker).filter { !$0.isEmpty } ?? [])
    return speakers.count > 1
      || speakers.contains {
        !(meeting.speakerNames?[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
  }
  private static func rendered(_ blocks: [ReadableBlock], meeting: Meeting) -> [String] {
    let labelSpeakers = shouldLabelSpeakers(meeting)
    return blocks.map { block in
      labelSpeakers ? speakerLabel(block.speaker, meeting: meeting) + block.text : block.text
    }
  }
  /// Presentation-only runs retain the canonical source ID. Their words come
  /// directly from recognition; edited prose keeps its original segment because
  /// its wording no longer has the recognition's measured word boundaries.
  static func speakerRuns(_ segment: Segment, raw: Bool = false) -> [Segment] {
    let text = raw ? segment.rawText : segment.text
    guard segment.status != "manual", !segment.isNote,
      let words = segment.captionWords, !words.isEmpty,
      words.map(\.text).joined(separator: " ") == text
    else { return [segment] }
    var runs: [Segment] = []
    for word in words {
      let speaker = word.speaker ?? segment.speaker
      if let last = runs.last, last.speaker == speaker {
        runs[runs.count - 1].text += " " + word.text
        runs[runs.count - 1].rawText += " " + word.text
        runs[runs.count - 1].end = max(last.end, word.end)
      } else {
        var run = segment
        run.start = word.start
        run.end = word.end
        run.speaker = speaker
        run.rawText = word.text
        run.text = word.text
        run.captionWords = nil
        runs.append(run)
      }
    }
    return runs
  }
  static func sourceBlocks(_ segments: [Segment], limit: Int = 1800) -> [ReadableBlock] {
    let limit = max(1, limit)
    var blocks: [ReadableBlock] = []
    var previous: Segment?
    for segment in segments.flatMap({ speakerRuns($0) }) {
      var remainder = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      while !remainder.isEmpty {
        let text: String
        if remainder.count > limit {
          let end = remainder.index(remainder.startIndex, offsetBy: limit)
          let candidate = remainder[..<end]
          // Prefer a word boundary; very long unbroken input still has a hard bound.
          let boundary = candidate.lastIndex(where: \.isWhitespace) ?? end
          let split = boundary == remainder.startIndex ? end : boundary
          text = String(remainder[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
          remainder = String(remainder[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
          text = remainder
          remainder = ""
        }
        guard !text.isEmpty else { continue }
        if let last = blocks.last, last.speaker == segment.speaker,
          (previous?.status == "manual") == (segment.status == "manual"),
          previous?.isNote == segment.isNote,
          last.text.count + 1 + text.count <= limit
        {
          blocks[blocks.count - 1].text += " " + text
          if last.sourceIDs.last != segment.id {
            blocks[blocks.count - 1].sourceIDs.append(segment.id)
          }
        } else {
          blocks.append(
            ReadableBlock(
              id: "B" + String(blocks.count + 1),
              speaker: segment.speaker, sourceIDs: [segment.id], text: text))
        }
      }
      previous = segment
    }
    return blocks
  }
}
