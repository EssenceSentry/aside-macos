import AsideAudio
import AsideWhisper
import Foundation

struct SpeakerReviewResult: Codable, Sendable {
  var labelsBySegmentID: [String: String]
  var warnings: [String]
  /// Cluster consistency against the user-confirmed reference, not identity probability.
  var referenceMatched: Bool = false
  var captionWordAssignments: [String: [CaptionWord]]? = nil
}

protocol SpeakerReviewing: Sendable {
  func review(
    chunks: [CapturedChunk], segments: [Segment], output: URL, reference: URL?,
    progress: (@Sendable (String) async -> Void)?
  ) async throws -> SpeakerReviewResult
}

/// Attribution of existing text only. No recognizer, rewriting, or passage splitting.
enum SpeakerReviewAttribution {
  static func source(for segment: Segment, chunks: [CapturedChunk]) -> String? {
    let matching = Set(
      chunks.filter {
        segment.id == $0.track.id || segment.id.hasPrefix($0.track.id + ":")
      }.map(\.speaker))
    if matching.count == 1 { return matching.first }
    if !matching.isEmpty { return nil }
    let sources = Set(chunks.map(\.speaker))
    return sources.count == 1 ? sources.first : nil
  }

  static func label(start: Double, end: Double, turns: [SpeakerTurn]) -> String {
    guard start.isFinite, end.isFinite, end > start else { return "Unknown speaker" }
    let relevant = turns.filter {
      $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        && $0.start < end && $0.end > start
    }
    let names = Set(relevant.flatMap { $0.speaker.components(separatedBy: " + ") })
    guard names.count == 1, let name = names.first,
      !name.isEmpty, name != "Unknown speaker"
    else { return "Unknown speaker" }
    let ranges = relevant.map { max(start, $0.start)..<min(end, $0.end) }
    let seconds = merged(ranges).reduce(0.0) { $0 + $1.upperBound - $1.lowerBound }
    return seconds >= (end - start) * 0.8 ? name : "Unknown speaker"
  }

  static func labels(
    segments: [Segment], chunks: [CapturedChunk], turnsBySource: [String: [SpeakerTurn]],
    excludedBySource: [String: [SpeechRegion]] = [:]
  ) -> SpeakerReviewResult {
    var labels: [String: String] = [:]
    var wordAssignments: [String: [CaptionWord]] = [:]
    var ambiguousSources = 0
    for segment in segments where !segment.isNote {
      let resolvedSource = source(for: segment, chunks: chunks)
      if segment.status != "manual", var words = segment.captionWords, !words.isEmpty,
        words.map(\.text).joined(separator: " ") == segment.rawText
      {
        if resolvedSource == nil { ambiguousSources += 1 }
        for i in words.indices {
          guard let source = resolvedSource else {
            words[i].speaker = "Unknown speaker"
            continue
          }
          let excluded = excludedBySource[source, default: []].contains {
            $0.start < words[i].end && $0.end > words[i].start
          }
          let name =
            excluded
            ? "Unknown speaker"
            : SpeakerAttribution.speaker(
              start: words[i].start, end: words[i].end,
              turns: turnsBySource[source, default: []])
          words[i].speaker = name.components(separatedBy: " + ").map { voice in
            voice == "You" || voice == "Unknown speaker" ? voice : source + " · " + voice
          }.sorted().joined(separator: " + ")
        }
        wordAssignments[segment.id] = words
        let names = Set(words.map { $0.speaker ?? "Unknown speaker" })
        labels[segment.id] = names.count == 1 ? names.first! : "Mixed speakers"
        continue
      }
      guard let source = resolvedSource else {
        labels[segment.id] = "Unknown speaker"
        ambiguousSources += 1
        continue
      }
      let excluded = excludedBySource[source, default: []].contains {
        $0.start < segment.end && $0.end > segment.start
      }
      let name =
        excluded
        ? "Unknown speaker"
        : label(
          start: segment.start, end: segment.end, turns: turnsBySource[source, default: []])
      labels[segment.id] = name == "You" || name == "Unknown speaker" ? name : source + " · " + name
    }
    let warnings =
      ambiguousSources > 0
      ? [
        String(ambiguousSources)
          + " passages have ambiguous audio-source provenance; their voice is unknown"
      ] : []
    return SpeakerReviewResult(
      labelsBySegmentID: labels, warnings: warnings,
      captionWordAssignments: wordAssignments.isEmpty ? nil : wordAssignments)
  }

  static func merged(_ ranges: [Range<Double>]) -> [Range<Double>] {
    var output: [Range<Double>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = output.last, range.lowerBound <= last.upperBound {
        output[output.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        output.append(range)
      }
    }
    return output
  }
}

struct SpeakerReviewAudioPiece: Sendable {
  var offset: Double
  var samples: [Float]
}
struct SpeakerReviewAudio: Sendable {
  var samples: [Float]
  var excluded: [SpeechRegion]
}

/// Gaps retain their original clock. Ambiguous overlapping samples are silenced
/// only in the inference copy and excluded from all attribution decisions.
enum SpeakerReviewTimeline {
  static func reconstruct(_ pieces: [SpeakerReviewAudioPiece]) throws -> SpeakerReviewAudio {
    var samples: [Float] = []
    var occupied: [Range<Int>] = []
    var overlaps: [Range<Double>] = []
    for piece in pieces.sorted(by: { $0.offset < $1.offset }) {
      guard piece.offset.isFinite, piece.offset >= 0, piece.offset <= 7200,
        piece.samples.allSatisfy(\.isFinite)
      else { throw AsideError("Speaker review requires finite audio and valid source offsets") }
      let start = Int((piece.offset * 16000).rounded())
      guard piece.samples.count <= 16000 * 7200 - start else {
        throw AsideError("Review recordings of up to two hours per source")
      }
      let end = start + piece.samples.count
      guard start < end else { continue }
      if samples.count < end {
        samples.append(contentsOf: repeatElement(0, count: end - samples.count))
      }
      var cursor = start
      for previous in occupied where previous.upperBound > start && previous.lowerBound < end {
        let lower = max(start, previous.lowerBound)
        let upper = min(end, previous.upperBound)
        if upper - lower > 16 { overlaps.append(Double(lower) / 16000..<Double(upper) / 16000) }
        if cursor < lower {
          samples.replaceSubrange(
            cursor..<lower, with: piece.samples[(cursor - start)..<(lower - start)])
        }
        cursor = max(cursor, upper)
      }
      if cursor < end {
        samples.replaceSubrange(cursor..<end, with: piece.samples[(cursor - start)..<(end - start)])
      }
      occupied.append(start..<end)
      occupied = mergedSamples(occupied)
    }
    let excluded = SpeakerReviewAttribution.merged(overlaps).map {
      SpeechRegion(start: $0.lowerBound, end: $0.upperBound)
    }
    for region in excluded {
      let start = Int((region.start * 16000).rounded())
      let end = Int((region.end * 16000).rounded())
      samples.replaceSubrange(start..<end, with: repeatElement(0, count: end - start))
    }
    return SpeakerReviewAudio(samples: samples, excluded: excluded)
  }

  private static func mergedSamples(_ ranges: [Range<Int>]) -> [Range<Int>] {
    var output: [Range<Int>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = output.last, range.lowerBound <= last.upperBound {
        output[output.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        output.append(range)
      }
    }
    return output
  }
}

actor SpeakerReviewService: SpeakerReviewing {
  private let speakers: SpeakerEngine
  private let voiceProfiles: VoiceProfileStore
  init(root: URL) {
    speakers = SpeakerEngine(root: root)
    voiceProfiles = VoiceProfileStore(root: root)
  }

  func review(
    chunks: [CapturedChunk], segments: [Segment], output: URL, reference: URL? = nil,
    progress: (@Sendable (String) async -> Void)? = nil
  ) async throws -> SpeakerReviewResult {
    guard await speakers.downloaded() else { throw SpeakerSetupError.missingModel }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    func save<T: Encodable>(_ value: T, name: String) throws {
      let path = output.appendingPathComponent(name + ".json")
      try encoder.encode(value).write(to: path, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    var warnings: [String] = []
    var referenceSamples: [Float]?
    if let reference {
      do {
        let loaded = try AudioPreparationModel.load(reference)
        if loaded.count >= 16000 * 8, loaded.allSatisfy(\.isFinite) {
          referenceSamples = loaded
        } else {
          warnings.append("Your solo reference needs at least eight seconds of usable audio")
        }
      } catch {
        warnings.append("Your reference voice could not be loaded: " + error.localizedDescription)
      }
    } else {
      warnings.append("No confirmed solo reference was provided; voices remain anonymous")
    }
    let knownReferences = (try? voiceProfiles.references()) ?? []
    var turns: [String: [SpeakerTurn]] = [:]
    var excluded: [String: [SpeechRegion]] = [:]
    var referenceMatched = false
    let groups = Dictionary(grouping: chunks, by: \.speaker).sorted { $0.key < $1.key }
    for (index, entry) in groups.enumerated() {
      try Task.checkCancellation()
      await progress?("Identifying voices in " + entry.key.lowercased())
      do {
        var pieces: [SpeakerReviewAudioPiece] = []
        for chunk in entry.value.sorted(by: { $0.offset < $1.offset }) {
          try Task.checkCancellation()
          pieces.append(
            SpeakerReviewAudioPiece(
              offset: chunk.offset,
              samples: try AudioPreparationModel.load(chunk.url)))
        }
        let audio = try SpeakerReviewTimeline.reconstruct(pieces)
        excluded[entry.key] = audio.excluded
        if !audio.excluded.isEmpty {
          warnings.append(
            "Overlapping audio chunks in " + entry.key.lowercased()
              + " were excluded from voice attribution; original recordings were retained")
        }
        try save(audio.excluded, name: "source-" + String(index + 1) + "-excluded")
        guard !audio.samples.isEmpty else {
          warnings.append("No saved audio in " + entry.key.lowercased())
          continue
        }
        let analysis = try await speakers.analyze(
          audio.samples, reference: referenceSamples, references: knownReferences)
        turns[entry.key] = analysis.turns
        referenceMatched = referenceMatched || analysis.referenceMatched
        try save(analysis, name: "source-" + String(index + 1) + "-analysis")
        try save(entry.key, name: "source-" + String(index + 1) + "-label")
        if referenceSamples != nil, !analysis.referenceMatched {
          warnings.append(
            "Your reference voice was not consistently matched in " + entry.key.lowercased())
        }
      } catch {
        if Task.isCancelled { throw CancellationError() }
        warnings.append(
          "Voice review in " + entry.key.lowercased() + ": " + error.localizedDescription)
      }
    }
    var result = SpeakerReviewAttribution.labels(
      segments: segments, chunks: chunks,
      turnsBySource: turns, excludedBySource: excluded)
    result.warnings = warnings + result.warnings
    result.referenceMatched = referenceMatched
    try save(result, name: "speaker-review")
    return result
  }
}
