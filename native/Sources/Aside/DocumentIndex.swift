import AppKit
import Foundation
import PDFKit

struct DocumentChunk: Codable, Sendable {
  let location: String
  let text: String
  // Stored once at import. Previously written indexes still decode.
  var searchTerms: Set<String>? = nil
}

struct IndexedDocument: Codable, Sendable {
  let record: DocumentRecord
  let chunks: [DocumentChunk]
  var briefing: [DocumentChunk]? = nil
}

struct RetrievedPassage: Encodable, Sendable {
  var ref: String
  let documentID: String
  let title: String
  let location: String
  var text: String
  var segmentID: String? = nil
  var meetingID: String? = nil
  var documentRevision: Int? = nil
  var segmentRevision: Int? = nil
}

enum DocumentIndex {
  enum Failure: LocalizedError {
    case unsupported, unreadable, tooLarge, empty
    var errorDescription: String? {
      switch self {
      case .unsupported: "Choose a TXT, Markdown, PDF or DOCX document."
      case .unreadable: "Aside couldn't read this document."
      case .tooLarge: "Choose a document under 32 MB and two million characters."
      case .empty: "No selectable text was found. Scanned documents need OCR first."
      }
    }
  }

  static func extract(_ url: URL, id: String, displayName: String? = nil) throws -> IndexedDocument
  {
    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard properties.isRegularFile == true, let size = properties.fileSize else {
      throw Failure.unreadable
    }
    guard size <= 32 * 1_024 * 1_024 else { throw Failure.tooLarge }
    let kind = url.pathExtension.lowercased()
    var chunks: [DocumentChunk] = []
    var characters = 0
    func append(_ text: String, page: String?) throws {
      guard characters + text.count <= 2_000_000 else { throw Failure.tooLarge }
      characters += text.count
      // Fixed-size passages split at word boundaries keep even single-line
      // conversions and long PDF pages searchable without clipping their tail.
      var cursor = text.startIndex
      var index = 0
      while cursor < text.endIndex {
        var end = text.index(cursor, offsetBy: 1000, limitedBy: text.endIndex) ?? text.endIndex
        if end < text.endIndex,
          let cut = text[cursor..<end].suffix(200).lastIndex(where: \.isWhitespace)
        {
          end = text.index(after: cut)
        }
        let section = text[cursor..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        if !section.isEmpty {
          index += 1
          let locator = page.map { "\($0) · passage \(index)" } ?? "Passage \(index)"
          chunks.append(.init(location: locator, text: section, searchTerms: terms(section)))
        }
        cursor = end
      }
    }
    switch kind {
    case "pdf":
      guard let document = PDFDocument(url: url), !document.isLocked else {
        throw Failure.unreadable
      }
      for index in 0..<document.pageCount {
        if let text = document.page(at: index)?.string {
          try append(text, page: "Page \(index + 1)")
        }
      }
    case "docx":
      let attributed = try NSAttributedString(
        url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
        documentAttributes: nil)
      try append(attributed.string, page: nil)
    case "txt", "md", "markdown":
      var encoding = String.Encoding.utf8
      let text = try String(contentsOf: url, usedEncoding: &encoding)
      try append(text, page: nil)
    default: throw Failure.unsupported
    }
    guard !chunks.isEmpty else { throw Failure.empty }
    return IndexedDocument(
      record: DocumentRecord(
        id: id, name: displayName ?? url.lastPathComponent, kind: kind, characters: characters,
        addedAt: ISO8601DateFormatter().string(from: Date())), chunks: chunks,
      briefing: makeBrief(chunks))
  }

  private static func makeBrief(_ chunks: [DocumentChunk]) -> [DocumentChunk] {
    guard !chunks.isEmpty else { return [] }
    let last = chunks.count - 1
    return Set([0, last / 2, last]).sorted().map { i in
      DocumentChunk(location: chunks[i].location, text: String(chunks[i].text.prefix(220)))
    }
  }

  // These excerpts are stable across questions, bounded even for a large library,
  // and citation-checked in exactly the same way as query-ranked passages.
  static func seed(_ documents: [IndexedDocument], selected: [String]) -> [RetrievedPassage] {
    let selectedIDs = Set(selected)
    let chosen = documents.filter { selectedIDs.contains($0.record.id) }.sorted {
      $0.record.id < $1.record.id
    }
    var result: [RetrievedPassage] = []
    for document in chosen.prefix(10) {
      for chunk in document.briefing ?? makeBrief(document.chunks) {
        result.append(
          RetrievedPassage(
            ref: "B" + String(result.count + 1),
            documentID: document.record.id, title: document.record.name, location: chunk.location,
            text: chunk.text))
      }
    }
    return result
  }

  private static let stopWords: Set<String> = Set(
    "a an and are as at be by can did do for from has how i in is it of on or our that the their these this to was we what which will with would you your al como con cual de del el en es esta hay la las lo los o para por que se sobre su un una y"
      .split(separator: " ").map(String.init))

  static func terms(_ text: String) -> Set<String> {
    Set(
      text.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
      )
      .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init).filter { !stopWords.contains($0) && !$0.isEmpty })
  }

  static func transcriptSource(_ segment: Segment, meeting: Meeting, ref: String, text: String)
    -> RetrievedPassage
  {
    let seconds = Int(max(0, segment.start))
    let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
    return RetrievedPassage(
      ref: ref, documentID: "meeting:" + meeting.id, title: "Meeting transcript",
      location: "\(time) · \(segment.speaker.prefix(80)) · \(segment.status)", text: text,
      segmentID: segment.id, meetingID: meeting.id, segmentRevision: segment.revision)
  }

  // Preserve the original quotation and locator for each window. Adjacent turns
  // have separate citations, including when they disagree.
  private struct MemoryWindow {
    var source: RetrievedPassage
    var unit: Int
    var speaker: String?
    var start: Double?
    var end: Double?
    var hits: Set<String>
  }

  private static func folded(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
  }

  /// Full current meeting text, retaining individual acoustic speaker runs and
  /// canonical versioned locators. User-written text supersedes covered ASR.
  static func transcript(_ meeting: Meeting) -> [RetrievedPassage] {
    windows(meeting, queryTerms: [], excluding: []).enumerated().map { index, window in
      var source = window.source
      source.ref = "R" + String(index + 1)
      return source
    }
  }

  private static func windows(
    _ meeting: Meeting, queryTerms: Set<String>, excluding: Set<String>
  ) -> [MemoryWindow] {
    var windows: [MemoryWindow] = []
    func append(
      _ source: RetrievedPassage, unit: Int, speaker: String?, start: Double? = nil,
      end: Double? = nil
    ) {
      let text = source.text
      var cursor = text.startIndex
      while cursor < text.endIndex {
        var stop = text.index(cursor, offsetBy: 900, limitedBy: text.endIndex) ?? text.endIndex
        if stop < text.endIndex,
          let cut = text[cursor..<stop].suffix(120).lastIndex(where: \.isWhitespace)
        {
          stop = text.index(after: cut)
        }
        var passage = source
        passage.text = String(text[cursor..<stop])
        windows.append(
          MemoryWindow(
            source: passage, unit: unit, speaker: speaker, start: start, end: end,
            hits: terms(passage.text).intersection(queryTerms)))
        cursor = stop
      }
    }
    var coveredIDs: Set<String> = []
    var paragraphCount = 0
    if let document = meeting.document, document.author == "user" {
      coveredIDs = manualCoveredSegmentIDs(document)
      // A free-form user edit invalidates the ASR wording and any stale speaker
      // annotations. Only reuse annotations attached to the exact saved text.
      let blocks = document.blocks ?? []
      let aligned = !blocks.isEmpty && blocks.map(\.text).joined(separator: "\n\n") == document.text
      let paragraphs = aligned ? blocks.map(\.text) : document.text.components(separatedBy: "\n\n")
      paragraphCount = paragraphs.count
      for (i, paragraph) in paragraphs.enumerated() where !paragraph.isEmpty {
        let lines = paragraph.split(whereSeparator: \.isNewline)
        let header =
          lines.first == "You:" && !lines.dropFirst().contains { $0.hasSuffix(":") } ? "You" : nil
        let speaker = aligned ? blocks[i].speaker : header
        let location =
          "Corrected document · paragraph \(i + 1)" + (speaker.map { " · " + $0 } ?? "")
        let source = RetrievedPassage(
          ref: "", documentID: "meeting-document:" + meeting.id,
          title: "Corrected meeting transcript", location: location, text: paragraph,
          meetingID: meeting.id, documentRevision: document.revision)
        append(source, unit: i, speaker: speaker)
      }
    }
    var unit = paragraphCount
    for segment in meeting.segments where !coveredIDs.contains(segment.id) {
      for run in TranscriptDocument.speakerRuns(segment) {
        if !excluding.contains(segment.id) {
          append(
            transcriptSource(run, meeting: meeting, ref: "", text: run.text),
            unit: unit, speaker: run.speaker, start: run.start, end: run.end)
        }
        unit += 1
      }
    }
    return windows
  }

  static func memory(
    _ meeting: Meeting, query: String, question: String? = nil, excluding: Set<String> = [],
    limit: Int = 6
  ) -> [RetrievedPassage] {
    guard limit > 0 else { return [] }
    let queryTerms = terms(query).subtracting(memoryQuestionWords)
    let windows = windows(meeting, queryTerms: queryTerms, excluding: excluding)
    let eligible = Array(windows.indices)
    var frequency: [String: Int] = [:]
    for i in eligible { for term in windows[i].hits { frequency[term, default: 0] += 1 } }
    let scores = windows.map { window in
      window.hits.reduce(0.0) {
        $0 + log1p(Double(eligible.count) / Double(frequency[$1, default: 1]))
      }
    }
    let ranked = eligible.filter { queryTerms.isEmpty || scores[$0] > 0 }.sorted {
      scores[$0] == scores[$1] ? $0 > $1 : scores[$0] > scores[$1]
    }
    guard !ranked.isEmpty else { return [] }
    var selected = Array(ranked.prefix((limit + 1) / 2))
    func add(_ i: Int) {
      if selected.count < limit && !selected.contains(i) { selected.append(i) }
    }
    // A reply may say “Actually, Friday” without repeating a query term.
    // Keep it alongside the quoted claim, bounded by time and turn distance.
    var neighbors: [(index: Int, anchor: Int, follow: Bool, qualification: Bool)] = []
    for (priority, anchor) in selected.enumerated() {
      for i in [anchor + 1, anchor - 1] where windows.indices.contains(i) {
        let neighbor = windows[i]
        guard abs(neighbor.unit - windows[anchor].unit) <= 1
        else { continue }
        let earlier = windows[min(i, anchor)]
        let later = windows[max(i, anchor)]
        if let end = earlier.end, let start = later.start, start - end > 12 { continue }
        let qualifies =
          folded(neighbor.source.text).range(
            of:
              #"\b(?:actually|correction|sorry|i (?:mean|meant)|take (?:that|it) back|my words back|independent|instead|but|however|except|provided|unless|no|perdon|quise decir|en realidad|pero|salvo)\b"#,
            options: .regularExpression) != nil
        neighbors.append((i, priority, i > anchor, qualifies))
      }
    }
    neighbors.sort {
      if $0.qualification != $1.qualification { return $0.qualification }
      if $0.follow != $1.follow { return $0.follow }
      return $0.anchor < $1.anchor
    }
    for neighbor in neighbors where neighbor.qualification { add(neighbor.index) }
    if selected.count < limit, !neighbors.contains(where: { $0.qualification }),
      let neighbor = neighbors.first(where: { !selected.contains($0.index) })
    {
      add(neighbor.index)
    }
    for i in ranked {
      guard selected.count < limit else { break }
      add(i)
    }
    // Present evidence in spoken order while keeping T1 on the best direct hit.
    return selected.enumerated().map { rank, i in
      var source = windows[i].source
      source.ref = "T" + String(rank + 1)
      return (i, source)
    }.sorted { $0.0 < $1.0 }.map(\.1)
  }

  private static let memoryQuestionWords = Set(
    "when who were does say said about tell me my have any meeting ask asked mention mentioned decide decided decisions decision agree agreed discuss discussed happened summarize summary details que dije yo sobre dijo hablamos reunion resumir"
      .split(separator: " ").map(String.init))

  static func retrieve(
    _ documents: [IndexedDocument], selected: [String], query: String, limit: Int = 8
  ) -> [RetrievedPassage] {
    let selectedIDs = Set(selected)
    let documents = documents.filter { selectedIDs.contains($0.record.id) && !$0.chunks.isEmpty }
    guard limit > 0 else { return [] }
    let tokens = terms(query)
    struct Match {
      let doc: Int
      let chunk: Int
      let tokens: Set<String>
    }
    var matches: [Match] = []
    var frequencies: [String: Int] = [:]
    let titleTokens = documents.map { terms($0.record.name).intersection(tokens) }
    for (doc, document) in documents.enumerated() {
      for (chunk, passage) in document.chunks.enumerated() {
        let hits = (passage.searchTerms ?? terms(passage.text)).intersection(tokens)
        for token in hits { frequencies[token, default: 0] += 1 }
        matches.append(Match(doc: doc, chunk: chunk, tokens: hits))
      }
    }
    let count = Double(matches.count)
    let ranked = matches.map { match -> (Match, Double) in
      let score =
        match.tokens.reduce(0.0) { score, token in
          score + log1p(count / Double(frequencies[token, default: 1]))
        } + 0.5 * Double(titleTokens[match.doc].count)
      return (match, score)
    }.sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      // Interleave across documents for broad questions with no distinguishing terms.
      if $0.0.chunk != $1.0.chunk { return $0.0.chunk < $1.0.chunk }
      return $0.0.doc < $1.0.doc
    }
    let relevant = ranked.first.map { $0.1 > 0 } == true ? ranked.prefix { $0.1 > 0 } : ranked[...]
    return relevant.prefix(limit).enumerated().map { index, row in
      let document = documents[row.0.doc]
      let chunk = document.chunks[row.0.chunk]
      return RetrievedPassage(
        ref: "S\(index + 1)", documentID: document.record.id,
        title: document.record.name, location: chunk.location, text: chunk.text)
    }
  }
}
