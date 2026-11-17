import Foundation

public struct RecognitionGap: Codable, Sendable, Equatable {
  public var start: Double
  public var end: Double
  public var speechSeconds: Double
  public init(start: Double, end: Double, speechSeconds: Double) {
    self.start = start
    self.end = end
    self.speechSeconds = speechSeconds
  }
}

public struct RecognitionTimingIssue: Codable, Sendable, Equatable {
  public var start: Double
  public var end: Double
  public var reason: String
}

public struct RecognitionCoverageAssessment: Codable, Sendable {
  public var verified: Bool
  public var complete: Bool
  public var gaps: [RecognitionGap]
  public var timingIssues: [RecognitionTimingIssue]
}

/// Checks acoustic speech support against recognized timing, without inventing
/// text or using a language model to decide what a missing sentence might say.
public enum RecognitionCoverage {
  /// Absence of acoustic evidence is different from a successful silence
  /// check. Contradictory ASR text with no detected speech is also unchecked.
  public static func assess(
    passages: [WhisperPassage], speech: [SpeakerTurn], duration: Double,
    evidenceAvailable: Bool
  ) -> RecognitionCoverageAssessment {
    let hasSpeech = speech.contains {
      $0.start.isFinite && $0.end.isFinite && min(duration, $0.end) > max(0, $0.start)
    }
    var verified = duration.isFinite && duration >= 0 && evidenceAvailable
    var issues: [RecognitionTimingIssue] = []
    var anchors: [Range<Double>] = []
    for passage in passages
    where !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if !hasSpeech { verified = false }
      guard let words = SpeakerAttribution.completeWords(passage, allowZeroDuration: true) else {
        verified = false
        issues.append(
          RecognitionTimingIssue(
            start: passage.start, end: passage.end,
            reason: "Missing or nonchronological timing for the canonical word sequence"))
        continue
      }
      let positive = words.filter { $0.end > $0.start }
      if positive.count < words.count {
        issues.append(
          RecognitionTimingIssue(
            start: passage.start, end: passage.end,
            reason: "Canonical words retained; some words have no duration for speaker alignment"))
        // Collapsed DTW words supply no acoustic evidence. The other lexical
        // anchors may support this passage only when independently voiced.
        let lexicalSpans = SpeakerAttribution.union(
          positive.compactMap { word -> Range<Double>? in
            guard word.text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return word.start..<word.end
          })
        let observed = lexicalSpans.reduce(0.0) { $0 + $1.upperBound - $1.lowerBound }
        let supported = lexicalSpans.reduce(0.0) {
          $0
            + speechSeconds(
              start: max(0, $1.lowerBound), end: min(duration, $1.upperBound), speech: speech)
        }
        // An isolated sliver of acoustic overlap cannot validate a passage
        // whose remaining words have no measured duration.
        if supported <= observed * 0.5 { verified = false }
      }
      if positive.contains(where: { $0.end <= 0 || $0.start >= duration }) { verified = false }
      anchors.append(contentsOf: positive.map { $0.start..<$0.end })
    }
    let missing = uncovered(anchors: anchors, speech: speech, duration: duration, minimumSpeech: 2)
    return RecognitionCoverageAssessment(
      verified: verified, complete: verified && missing.isEmpty, gaps: missing,
      timingIssues: issues)
  }

  /// Repair proposals protect existing untimed text from duplicate insertion.
  /// Certification above uses only observed word intervals, never this coarse fallback.
  public static func gaps(
    passages: [WhisperPassage], speech: [SpeakerTurn], duration: Double,
    minimumSpeech: Double = 2
  ) -> [RecognitionGap] {
    let anchors = passages.flatMap { passage -> [Range<Double>] in
      guard !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
      if let words = SpeakerAttribution.completeWords(passage, allowZeroDuration: true) {
        return words.compactMap { $0.end > $0.start ? $0.start..<$0.end : nil }
      }
      guard passage.start.isFinite, passage.end.isFinite, passage.end > passage.start else {
        return []
      }
      return [passage.start..<passage.end]
    }
    return uncovered(
      anchors: anchors, speech: speech, duration: duration, minimumSpeech: minimumSpeech)
  }

  private static func uncovered(
    anchors: [Range<Double>], speech: [SpeakerTurn], duration: Double, minimumSpeech: Double
  ) -> [RecognitionGap] {
    guard duration.isFinite, duration > 0 else { return [] }
    func clipped(_ start: Double, _ end: Double) -> Range<Double>? {
      guard start.isFinite, end.isFinite else { return nil }
      let lower = max(0, start)
      let upper = min(duration, end)
      return lower < upper ? lower..<upper : nil
    }
    let voiced = SpeakerAttribution.union(speech.compactMap { clipped($0.start, $0.end) })
    let recognized = SpeakerAttribution.union(
      anchors.compactMap { clipped($0.lowerBound - 0.5, $0.upperBound + 0.5) })
    var missing: [Range<Double>] = []
    for voice in voiced {
      var cursor = voice.lowerBound
      for covered in recognized
      where covered.upperBound > cursor && covered.lowerBound < voice.upperBound {
        if covered.lowerBound > cursor {
          missing.append(cursor..<min(covered.lowerBound, voice.upperBound))
        }
        cursor = max(cursor, covered.upperBound)
        if cursor >= voice.upperBound { break }
      }
      if cursor < voice.upperBound { missing.append(cursor..<voice.upperBound) }
    }
    var grouped: [RecognitionGap] = []
    for range in missing {
      let seconds = range.upperBound - range.lowerBound
      if let last = grouped.last, range.lowerBound - last.end <= 0.8 {
        grouped[grouped.count - 1].end = range.upperBound
        grouped[grouped.count - 1].speechSeconds += seconds
      } else {
        grouped.append(
          RecognitionGap(start: range.lowerBound, end: range.upperBound, speechSeconds: seconds))
      }
    }
    return grouped.filter { $0.speechSeconds >= minimumSpeech }
  }

  private static func speechSeconds(
    start: Double, end: Double, speech: [SpeakerTurn]
  ) -> Double {
    guard start.isFinite, end.isFinite, end > start else { return 0 }
    let ranges = speech.compactMap { turn -> Range<Double>? in
      guard turn.start.isFinite, turn.end.isFinite else { return nil }
      let lower = max(start, turn.start)
      let upper = min(end, turn.end)
      return lower < upper ? lower..<upper : nil
    }
    return SpeakerAttribution.union(ranges).reduce(0.0) {
      $0 + $1.upperBound - $1.lowerBound
    }
  }

  /// A missing ASR interval is not permission to decode silence with a relaxed
  /// first-token gate. Independent acoustic speech must qualify each retry.
  public static func retryEligible(_ gap: RecognitionGap, speech: [SpeakerTurn]) -> Bool {
    speechSeconds(start: gap.start, end: gap.end, speech: speech) >= 0.08
  }

  /// Keep every original passage. Padded retry audio may repeat neighboring
  /// words; only words whose centers lie in an uncovered interval are added.
  public static func merge(
    original: [WhisperPassage], repairs: [WhisperPassage], gaps: [RecognitionGap],
    speech: [SpeakerTurn]? = nil
  ) -> [WhisperPassage] {
    let protected: [Range<Double>] = original.flatMap { passage in
      if let words = SpeakerAttribution.completeWords(passage) {
        return words.map { $0.start..<$0.end }
      }
      guard !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        passage.start.isFinite, passage.end.isFinite, passage.end > passage.start
      else { return [] }
      return [passage.start..<passage.end]
    }
    func touchesOriginal(_ start: Double, _ end: Double) -> Bool {
      protected.contains { start < $0.upperBound && end > $0.lowerBound }
    }
    var additions: [WhisperPassage] = []
    for passage in repairs {
      if let words = SpeakerAttribution.completeWords(passage) {
        for gap in gaps {
          let selected = words.filter { word in
            let center = (word.start + word.end) / 2
            return center >= gap.start && center < gap.end
              && !touchesOriginal(word.start, word.end)
          }
          // Accept the selected canonical phrase atomically. Removing just an
          // unsupported negation or qualifier could change the speaker's claim.
          if let speech,
            !selected.allSatisfy({ word in
              speechSeconds(start: word.start, end: word.end, speech: speech)
                > (word.end - word.start) * 0.5
            })
          {
            continue
          }
          guard let first = selected.first, let last = selected.last else { continue }
          additions.append(
            WhisperPassage(
              text: selected.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
              start: first.start, end: last.end, words: selected))
        }
      } else if speech == nil,
        gaps.contains(where: { passage.start >= $0.start && passage.end <= $0.end }),
        !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !touchesOriginal(passage.start, passage.end)
      {
        // Incomplete word timing cannot safely trim a padded boundary. Preserve
        // complete untimed passages only when they fit wholly inside the gap.
        additions.append(passage)
      }
    }
    return (original + additions).enumerated().sorted {
      $0.element.start == $1.element.start
        ? $0.offset < $1.offset : $0.element.start < $1.element.start
    }.map(\.element)
  }

  /// Compare lexical content without guessing equivalences between different
  /// words. Numbers, decimal points, negation, units and contractions survive.
  public static func canonicalTokens(_ text: String) -> [String] {
    let pattern = #"[\p{L}\p{N}]+(?:[’'.-][\p{L}\p{N}]+)*|[%$€£]|[+-](?=\d)"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let fillers: Set<String> = ["um", "uh", "umm", "ummm", "erm", "ehm", "emm", "hmm"]
    return expression.matches(in: text, range: range).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      let token = text[range].lowercased().replacingOccurrences(of: "’", with: "'")
      return fillers.contains(token) ? nil : token
    }
  }

  /// Replace only an unpublished ASR candidate whose timing is already known
  /// to be unreliable. A fresh direct-audio alternative must be complete,
  /// independently speech-supported, and cover the target acoustic interval.
  /// Callers retain both candidates in their private recognition audit.
  public static func replacingUnreliableCandidate(
    _ original: [WhisperPassage], at index: Int, with alternatives: [WhisperPassage],
    speech: [SpeakerTurn], duration: Double
  ) -> [WhisperPassage]? {
    guard original.indices.contains(index),
      SpeakerAttribution.completeWords(original[index]) == nil
    else { return nil }
    let target = original[index]
    guard target.start.isFinite, target.end.isFinite, target.end > target.start else { return nil }
    let gap = RecognitionGap(
      start: target.start, end: target.end, speechSeconds: target.end - target.start)
    let support = speech.compactMap { turn -> SpeakerTurn? in
      let start = max(target.start, turn.start)
      let end = min(target.end, turn.end)
      return start < end ? SpeakerTurn(speaker: "Detected speech", start: start, end: end) : nil
    }
    guard retryEligible(gap, speech: support) else { return nil }
    let trimmed = WhisperEngine.retainIndependentWindow(
      alternatives,
      window: WhisperAudioWindow(
        coreStart: target.start, coreEnd: target.end, audioStart: target.start, audioEnd: target.end
      ))
    guard trimmed.timingIssues.isEmpty, !trimmed.retained.isEmpty,
      canonicalTokens(target.text)
        == canonicalTokens(trimmed.retained.map(\.text).joined(separator: " "))
    else { return nil }
    let accepted = merge(original: [], repairs: trimmed.retained, gaps: [gap], speech: support)
    // Do not selectively lose a qualifier/negation because of a VAD disagreement.
    guard accepted.map(\.text) == trimmed.retained.map(\.text) else { return nil }
    let assessment = assess(
      passages: accepted, speech: support, duration: duration, evidenceAvailable: true)
    guard assessment.verified, assessment.complete else { return nil }
    var updated = original
    updated.replaceSubrange(index...index, with: accepted)
    return updated
  }

  public static func shifted(_ passages: [WhisperPassage], by offset: Double) -> [WhisperPassage] {
    passages.map {
      WhisperPassage(
        text: $0.text, start: $0.start + offset, end: $0.end + offset,
        words: $0.words?.map {
          WhisperWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        })
    }
  }
}
