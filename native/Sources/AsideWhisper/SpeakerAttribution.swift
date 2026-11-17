import Foundation

public struct AttributedPassage: Sendable {
  public var speaker: String
  public var text: String
  public var start: Double
  public var end: Double
  public init(speaker: String, text: String, start: Double, end: Double) {
    self.speaker = speaker
    self.text = text
    self.start = start
    self.end = end
  }
}

public enum SpeakerAttribution {
  /// Require support across most of a word. A nearby voice is not evidence
  /// that it spoke a word in a diarization gap; a tied changeover is unknown.
  public static func speaker(start: Double, end: Double, turns: [SpeakerTurn]) -> String {
    guard start.isFinite, end.isFinite, end > start else { return "Unknown speaker" }
    let length = end - start
    var intervals: [String: [Range<Double>]] = [:]
    for turn in turns where turn.start.isFinite && turn.end.isFinite {
      let lower = max(start, turn.start)
      let upper = min(end, turn.end)
      guard lower < upper else { continue }
      for name in turn.speaker.components(separatedBy: " + ") where name != "Unknown speaker" {
        intervals[name, default: []].append(lower..<upper)
      }
    }
    var merged: [String: [Range<Double>]] = [:]
    for (name, ranges) in intervals { merged[name] = union(ranges) }
    var ranked: [(name: String, duration: Double)] = []
    for (name, ranges) in merged {
      var duration: Double = 0
      for range in ranges { duration += range.upperBound - range.lowerBound }
      ranked.append((name: name, duration: duration))
    }
    ranked.sort {
      if $0.duration == $1.duration { return $0.name < $1.name }
      return $0.duration > $1.duration
    }
    guard let first = ranked.first, first.duration > length * 0.5 else {
      return "Unknown speaker"
    }
    let candidates = ranked.filter { $0.duration > length * 0.5 }.map(\.name)
    if candidates.count > 1 {
      // Joint labels mean simultaneous support, not two successive speakers
      // each occupying a different half of a long untimed passage.
      return candidates.sorted().joined(separator: " + ")
    }
    return first.name
  }

  static func union(_ ranges: [Range<Double>]) -> [Range<Double>] {
    var result: [Range<Double>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      if let last = result.last, range.lowerBound <= last.upperBound {
        result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        result.append(range)
      }
    }
    return result
  }

  /// Align timing tokens back to the authoritative recognized text. Whisper's
  /// optional word list can be incomplete; never silently discard passage text.
  static func completeWords(
    _ passage: WhisperPassage, allowZeroDuration: Bool = false
  ) -> [WhisperWord]? {
    guard let words = passage.words, !words.isEmpty else { return nil }
    var cursor = passage.text.startIndex
    var result: [WhisperWord] = []
    for word in words {
      let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty else { continue }
      guard word.start.isFinite, word.end.isFinite,
        allowZeroDuration ? word.end >= word.start : word.end > word.start,
        result.last.map({ word.start >= $0.start && word.end >= $0.end }) ?? true,
        let range = passage.text.range(of: token, range: cursor..<passage.text.endIndex),
        !passage.text[cursor..<range.lowerBound].contains(where: { $0.isLetter || $0.isNumber })
      else { return nil }
      let gap = String(passage.text[cursor..<range.lowerBound])
      if !result.isEmpty { result[result.count - 1].text += gap }
      result.append(
        WhisperWord(
          text: (result.isEmpty ? gap : "") + String(passage.text[range]),
          start: word.start, end: word.end))
      cursor = range.upperBound
    }
    guard !result.isEmpty,
      !passage.text[cursor...].contains(where: { $0.isLetter || $0.isNumber })
    else { return nil }
    result[result.count - 1].text += String(passage.text[cursor...])
    return result
  }

  public static func align(_ passages: [WhisperPassage], turns: [SpeakerTurn])
    -> [AttributedPassage]
  {
    var output: [AttributedPassage] = []
    for passage in passages {
      guard !passage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      guard let words = completeWords(passage, allowZeroDuration: true) else {
        let supported = Set(
          turns.filter {
            $0.start < passage.end && $0.end > passage.start
          }.flatMap { $0.speaker.components(separatedBy: " + ") }
        ).subtracting(["Unknown speaker"])
        let label =
          supported.count > 1
          ? "Unknown speaker" : speaker(start: passage.start, end: passage.end, turns: turns)
        output.append(
          AttributedPassage(
            speaker: label, text: passage.text, start: passage.start, end: passage.end))
        continue
      }
      // Do not merge independent recognition passages: their whitespace and
      // timing may have gaps, and their original boundaries remain inspectable.
      let boundary = output.count
      for word in words {
        let label = speaker(start: word.start, end: word.end, turns: turns)
        if output.count > boundary, let last = output.last, last.speaker == label,
          word.start >= last.start, word.start - last.end < 1.5, last.text.count < 1000
        {
          output[output.count - 1].text += word.text
          output[output.count - 1].end = max(last.end, word.end)
        } else {
          output.append(
            AttributedPassage(speaker: label, text: word.text, start: word.start, end: word.end))
        }
      }
    }
    return output.map { value in
      var value = value
      value.text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return value
    }.filter { !$0.text.isEmpty }
  }
}
