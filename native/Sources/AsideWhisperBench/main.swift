import AVFoundation
import AsideAudio
import AsideWhisper
import FluidAudio
import Foundation

private actor CachedParakeetAlternative {
  private let directory: URL
  private var manager: AsrManager?
  init(root: URL) { directory = root.appendingPathComponent("models/parakeet-v3") }
  func available() -> Bool { AsrModels.modelsExist(at: directory) }
  func transcribe(_ samples: [Float]) async throws -> [WhisperPassage] {
    if manager == nil {
      ModelHub.offlineMode = true
      let models = try await AsrModels.load(from: directory, version: .v3)
      let loaded = AsrManager(config: .default)
      try await loaded.loadModels(models)
      manager = loaded
    }
    var decoder = try TdtDecoderState()
    let recognized = try await manager!.transcribe(samples, decoderState: &decoder)
    let words = buildWordTimings(from: recognized.tokenTimings ?? [])
    return [
      WhisperPassage(
        text: recognized.text, start: 0, end: Double(samples.count) / 16000,
        words: words.map { WhisperWord(text: $0.word, start: $0.startTime, end: $0.endTime) })
    ]
  }
}

@main
struct WhisperBenchmark {
  static func main() async throws {
    let args = CommandLine.arguments
    if args.count >= 5, args[1] == "--audit" {
      let object =
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2])))
        as! [String: Any]
      let passages = try JSONDecoder().decode(
        [WhisperPassage].self, from: JSONSerialization.data(withJSONObject: object["passages"]!))
      let regions = try JSONDecoder().decode(
        [SpeechRegion].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
      let offset = object["startSeconds"] as? Double ?? 0
      let duration = object["audioSeconds"] as! Double
      let turns = regions.compactMap { value -> SpeakerTurn? in
        let start = max(0, value.start - offset)
        let end = min(duration, value.end - offset)
        return start < end ? SpeakerTurn(speaker: "Detected speech", start: start, end: end) : nil
      }
      let assessment = RecognitionCoverage.assess(
        passages: passages, speech: turns, duration: duration, evidenceAvailable: true)
      let output = URL(fileURLWithPath: args[4])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(assessment).write(to: output, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      print(
        "Acoustic gaps: \(assessment.gaps.count); timing uncertainties: \(assessment.timingIssues.count); verified: \(assessment.verified)"
      )
      return
    }
    if args.count >= 5, args[1] == "--speakers" {
      let engine = SpeakerEngine(root: URL(fileURLWithPath: args[2]))
      print("Preparing speaker model")
      try await engine.prepare(download: args.contains("--download"))
      let samples = try AudioPreparationModel.load(URL(fileURLWithPath: args[3]))
      print("Identifying voices in \(Double(samples.count) / 16000) seconds of audio")
      let started = Date()
      let reference: [Float]?
      if let i = args.firstIndex(of: "--reference"), args.indices.contains(i + 1) {
        reference = try AudioPreparationModel.load(URL(fileURLWithPath: args[i + 1]))
      } else {
        reference = nil
      }
      let analysis = try await engine.analyze(samples, reference: reference)
      let turns = analysis.turns
      let output = URL(fileURLWithPath: args[4])
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let data = try JSONEncoder().encode(analysis)
      try data.write(to: output, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      print(
        "Found \(Set(turns.map(\.speaker)).count) speakers and \(turns.count) turns in \(Date().timeIntervalSince(started)) seconds"
      )
      return
    }
    if args.count >= 5, args[1] == "--file" {
      let engine = WhisperEngine(root: URL(fileURLWithPath: args[2]))
      try await engine.prepare(download: false)
      let original = try AudioPreparationModel.load(URL(fileURLWithPath: args[3]))
      func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
      }
      let from = max(0, Double(value("--from") ?? "0") ?? 0)
      let to = min(
        Double(original.count) / 16000,
        Double(value("--to") ?? "") ?? Double(original.count) / 16000)
      guard to > from else { throw PreparationError.invalidSamples }
      let samples = Array(original[Int(from * 16000)..<Int(to * 16000)])
      let started = Date()
      let output = URL(fileURLWithPath: args[4])
      let audit = output.deletingPathExtension().appendingPathExtension("audit")
      try FileManager.default.createDirectory(
        at: audit, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      func checkpoint<T: Encodable>(_ item: T, _ name: String) throws {
        let path = audit.appendingPathComponent(name + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(item).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      }
      let language: String? = args.contains("--auto-language") ? nil : "en"
      let firstTokenGate: Float? =
        value("--first-token-gate") == "none"
        ? nil : Float(value("--first-token-gate") ?? "-1.5")
      let fallbackCount = max(0, Int(value("--fallback-count") ?? "0") ?? 0)
      let needsSpeech =
        args.contains("--repair-speech") || args.contains("--accept-speech")
        || value("--speech-regions") != nil
      let turns: [SpeakerTurn]
      if let path = value("--speech-regions") {
        let regions = try JSONDecoder().decode(
          [SpeechRegion].self,
          from: Data(contentsOf: URL(fileURLWithPath: path)))
        turns = regions.compactMap {
          let start = max(0, $0.start - from)
          let end = min(Double(samples.count) / 16000, $0.end - from)
          return start < end ? SpeakerTurn(speaker: "Detected speech", start: start, end: end) : nil
        }
      } else if needsSpeech {
        let detector = AudioPreparationModel(
          directory: URL(fileURLWithPath: args[2])
            .appendingPathComponent("models/audio-preparation"))
        let regions = try await detector.speechRegions(samples, allowDownload: false)
        turns = regions.map {
          SpeakerTurn(speaker: "Detected speech", start: $0.start, end: $0.end)
        }
      } else {
        turns = []
      }
      if needsSpeech { try checkpoint(turns, "speech-evidence") }
      var passages: [WhisperPassage]
      let independent: WhisperWindowRecognition?
      if args.contains("--independent") {
        independent = try await engine.transcribeIndependent(
          samples, language: language,
          firstTokenLogProbThreshold: firstTokenGate, temperatureFallbackCount: fallbackCount,
          windowCompleted: { window in
            let path = audit.appendingPathComponent(
              "window-" + String(Int(window.window.coreStart)) + ".json")
            try JSONEncoder().encode(window).write(to: path, options: .atomic)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: path.path)
          },
          progress: { fraction in
            print("Windowed recognition: " + String(Int(fraction * 100)) + "%")
          })
        passages = independent!.passages
      } else {
        independent = nil
        passages = try await engine.transcribe(
          samples, language: language, vad: args.contains("--vad"),
          words: args.contains("--words") || needsSpeech,
          firstTokenLogProbThreshold: firstTokenGate, temperatureFallbackCount: fallbackCount,
          progress: { fraction in print("Recognition: " + String(Int(fraction * 100)) + "%") })
      }
      try checkpoint(passages, "initial")
      let duration = Double(samples.count) / 16000
      if args.contains("--accept-speech") {
        passages = RecognitionCoverage.merge(
          original: [], repairs: passages,
          gaps: [RecognitionGap(start: 0, end: duration, speechSeconds: duration)], speech: turns)
        try checkpoint(passages, "accepted")
      }
      if args.contains("--repair-speech") {
        let parakeet = CachedParakeetAlternative(root: URL(fileURLWithPath: args[2]))
        let parakeetAvailable = await parakeet.available()
        try checkpoint(
          RecognitionCoverage.assess(
            passages: passages, speech: turns,
            duration: duration, evidenceAvailable: true), "coverage-initial")
        let uncertain = passages.filter {
          let assessment = RecognitionCoverage.assess(
            passages: [$0], speech: turns,
            duration: duration, evidenceAvailable: true)
          return !assessment.verified && !assessment.timingIssues.isEmpty
        }
        for (index, candidate) in uncertain.prefix(8).enumerated() {
          guard candidate.start >= 0, candidate.end <= duration,
            candidate.end > candidate.start, candidate.end - candidate.start <= 22,
            RecognitionCoverage.retryEligible(
              RecognitionGap(
                start: candidate.start,
                end: candidate.end, speechSeconds: candidate.end - candidate.start), speech: turns),
            let position = passages.firstIndex(where: {
              $0.start == candidate.start && $0.end == candidate.end && $0.text == candidate.text
            })
          else { continue }
          let lower = max(0, Int(((candidate.start - 1.5) * 16000).rounded(.down)))
          let upper = min(samples.count, Int(((candidate.end + 1.5) * 16000).rounded(.up)))
          let retry = try await engine.transcribe(
            Array(samples[lower..<upper]), language: language,
            words: true, firstTokenLogProbThreshold: nil)
          let shifted = RecognitionCoverage.shifted(retry, by: Double(lower) / 16000)
          try checkpoint(shifted, "timing-retry-" + String(index))
          var updated = RecognitionCoverage.replacingUnreliableCandidate(
            passages, at: position, with: shifted, speech: turns, duration: duration)
          if updated == nil, parakeetAvailable {
            let fallback = try await parakeet.transcribe(Array(samples[lower..<upper]))
            let shiftedFallback = RecognitionCoverage.shifted(fallback, by: Double(lower) / 16000)
            try checkpoint(shiftedFallback, "timing-parakeet-" + String(index))
            updated = RecognitionCoverage.replacingUnreliableCandidate(
              passages, at: position, with: shiftedFallback, speech: turns, duration: duration)
          }
          if let updated { passages = updated }
          try checkpoint(passages, "merged")
        }
        let gaps = RecognitionCoverage.gaps(passages: passages, speech: turns, duration: duration)
        let maximum = max(1, Int(value("--max-retries") ?? "12") ?? 12)
        var retries = 0
        for gap in gaps {
          var cursor = gap.start
          while cursor < gap.end && retries < maximum {
            let end = min(gap.end, cursor + 22)
            let target = RecognitionGap(start: cursor, end: end, speechSeconds: end - cursor)
            cursor = end
            guard RecognitionCoverage.retryEligible(target, speech: turns) else { continue }
            let lower = max(0, Int(((target.start - 1.5) * 16000).rounded(.down)))
            let upper = min(samples.count, Int(((target.end + 1.5) * 16000).rounded(.up)))
            let retry = try await engine.transcribe(
              Array(samples[lower..<upper]), language: language,
              words: true, firstTokenLogProbThreshold: nil)
            let shifted = RecognitionCoverage.shifted(retry, by: Double(lower) / 16000)
            retries += 1
            try checkpoint(shifted, "speech-retry-" + String(retries))
            passages = RecognitionCoverage.merge(
              original: passages, repairs: shifted,
              gaps: [target], speech: turns)
            try checkpoint(passages, "merged")
            print("Speech recovery window " + String(retries))
          }
        }
        if parakeetAvailable {
          let remaining = RecognitionCoverage.gaps(
            passages: passages, speech: turns, duration: duration)
          for (index, gap) in remaining.prefix(12).enumerated() {
            guard RecognitionCoverage.retryEligible(gap, speech: turns) else { continue }
            let lower = max(0, Int(((gap.start - 1) * 16000).rounded(.down)))
            let upper = min(
              samples.count, Int(((min(gap.end, gap.start + 22) + 1) * 16000).rounded(.up)))
            let fallback = try await parakeet.transcribe(Array(samples[lower..<upper]))
            let shifted = RecognitionCoverage.shifted(fallback, by: Double(lower) / 16000)
            try checkpoint(shifted, "speech-parakeet-" + String(index))
            passages = RecognitionCoverage.merge(
              original: passages, repairs: shifted,
              gaps: [gap], speech: turns)
            try checkpoint(passages, "merged")
          }
        }
      }
      var value: [String: Any] = [
        "input": args[3], "startSeconds": from, "audioSeconds": Double(samples.count) / 16000,
        "elapsedSeconds": Date().timeIntervalSince(started), "vad": args.contains("--vad"),
        "transcript": passages.map(\.text).joined(separator: " "),
        "passages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(passages)),
      ]
      if needsSpeech {
        let assessment = RecognitionCoverage.assess(
          passages: passages, speech: turns,
          duration: duration, evidenceAvailable: true)
        try checkpoint(assessment, "coverage-final")
        value["coverage"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(assessment))
      }
      if let independent {
        value["independentWindows"] = try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(independent))
      }
      try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: output, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      print("Recognized \(passages.count) passages in \(Date().timeIntervalSince(started)) seconds")
      return
    }
    guard args.count >= 4 else {
      print("Usage: AsideWhisperBench model-root input-directory output.json [--download]")
      return
    }
    let engine = WhisperEngine(root: URL(fileURLWithPath: args[1]))
    try await engine.prepare(download: args.contains("--download"))
    let input = URL(fileURLWithPath: args[2])
    let output = URL(fileURLWithPath: args[3])
    var variants: [[String: Any]] = []
    for name in ["long-context-original", "pauses-350ms", "pauses-filler-masked-experimental"] {
      let file = try AVAudioFile(forReading: input.appendingPathComponent(name + ".wav"))
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
      try file.read(into: buffer)
      guard file.processingFormat.sampleRate == 16000 else { return }
      let samples = Array(
        UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
      for vad in [false, true] {
        let start = Date()
        let passages = try await engine.transcribe(samples, language: "en", vad: vad)
        let elapsed = Date().timeIntervalSince(start)
        let text = passages.map(\.text).joined(separator: " ")
        let label = "whisperkit/" + name + (vad ? "/vad" : "/default")
        variants.append([
          "name": label, "model": "Whisper Turbo Core ML", "transcript": text,
          "elapsedSeconds": elapsed,
          "metrics": ["originalSeconds": 53, "preparedSeconds": Double(samples.count) / 16000],
        ])
        try FileManager.default.createDirectory(
          at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        let value: [String: Any] = ["startSeconds": 35.5, "endSeconds": 88.5, "variants": variants]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
          .write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print(
          String(format: "%@: %.2fs, %d words", label, elapsed, text.split(separator: " ").count))
      }
    }
  }
}
