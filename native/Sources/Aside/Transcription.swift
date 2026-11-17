import AsideAudio
import AsideWhisper
import FluidAudio
import Foundation

actor TranscriptionEngine {
  private var manager: AsrManager?
  private var retainedModels: AsrModels?
  private var loading: Task<Void, Error>?
  private var liveWhisperReady = false
  private var liveSpeakersReady = false
  private var speakers: SpeakerEngine
  private var finalRecognition: WhisperEngine
  private var audioPreparation: AudioPreparationModel
  private let modelCacheRoot: URL
  private var modelOwnership = AcousticModelOwnership()
  private let voiceProfiles: VoiceProfileStore
  let modelDirectory: URL
  init(root: URL, modelRoot: URL? = nil) {
    let cache = modelRoot ?? root
    modelCacheRoot = cache
    modelDirectory = cache.appendingPathComponent("models/parakeet-v3")
    voiceProfiles = VoiceProfileStore(root: root)
    speakers = SpeakerEngine(root: cache)
    finalRecognition = WhisperEngine(root: cache)
    audioPreparation = AudioPreparationModel(
      directory: cache.appendingPathComponent("models/audio-preparation"))
    ModelHub.offlineMode = true
  }
  func speakersDownloaded() async -> Bool { await speakers.downloaded() }
  func prepareSpeakers(download: Bool) async throws {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    try await speakers.prepare(download: download)
    liveSpeakersReady = true
  }
  func finalDownloaded() async -> Bool { await finalRecognition.downloaded() }
  func prepareFinal(download: Bool) async throws {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    try await finalRecognition.prepare(download: download)
    liveWhisperReady = true
  }
  func prepareCoverage(download: Bool) async throws {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    _ = try await audioPreparation.speechRegions(
      [Float](repeating: 0, count: 16000), allowDownload: download)
  }
  func downloaded() -> Bool { AsrModels.modelsExist(at: modelDirectory) }
  func prepare(download: Bool) async throws {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    if manager != nil { return }
    if let loading {
      try await loading.value
      return
    }
    let task = Task { try await self.load(download: download) }
    loading = task
    defer { loading = nil }
    try await task.value
  }
  /// The controller calls this only with capture and caption sessions idle.
  /// Detach the old generation before awaiting SDK cleanup: actor reentrancy
  /// may start new recognition during cleanup, and it must get fresh models.
  func releaseIdleModels() async -> Bool {
    guard let retirement = modelOwnership.beginRetirement() else { return false }
    defer { modelOwnership.endRetirement(retirement) }
    let oldManager = manager
    let oldWhisper = finalRecognition
    let oldSpeakers = speakers
    manager = nil
    retainedModels = nil
    liveWhisperReady = false
    liveSpeakersReady = false
    finalRecognition = WhisperEngine(root: modelCacheRoot)
    speakers = SpeakerEngine(root: modelCacheRoot)
    audioPreparation = AudioPreparationModel(
      directory: modelCacheRoot.appendingPathComponent("models/audio-preparation"))
    await oldManager?.cleanup()
    await oldWhisper.releaseRetiredResources()
    await oldSpeakers.releaseRetiredResources()
    return true
  }

  private func load(download: Bool) async throws {
    let models: AsrModels
    if download {
      ModelHub.offlineMode = false
      defer { ModelHub.offlineMode = true }
      models = try await AsrModels.downloadAndLoad(
        to: modelDirectory, version: .v3, encoderComputeUnits: .cpuAndGPU)
    } else {
      guard AsrModels.modelsExist(at: modelDirectory) else {
        throw AsideError("Download Parakeet TDT v3 to transcribe. Audio remains safely saved.")
      }
      // The Mac GPU path avoids the observed ANE encoder-specialization failure.
      // Decoder/joint placement and the recognizer weights stay unchanged.
      models = try await AsrModels.load(
        from: modelDirectory, version: .v3, encoderComputeUnits: .cpuAndGPU)
    }
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    retainedModels = models
    manager = asr
  }
  func makeLiveCaptionSession(
    source: String, generation: String,
    onUpdate: @escaping @Sendable (LiveCaptionSnapshot) async throws -> Void
  ) async throws -> (any LiveCaptionSession)? {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    try await prepare(download: false)
    guard let retainedModels else {
      throw AsideError("Speech models are unavailable for live captions")
    }
    return try await StreamingCaptionSession.open(
      models: retainedModels, source: source, generation: generation, onUpdate: onUpdate)
  }
  func transcribe(_ chunk: CapturedChunk) async throws -> [Segment] {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    try await prepare(download: false)
    guard let manager else { throw AsideError("Speech model unavailable") }
    var decoder = try TdtDecoderState()
    let result = try await manager.transcribe(chunk.url, decoderState: &decoder)
    let words = buildWordTimings(from: result.tokenTimings ?? [])
    let timingText = words.map(\.word).joined(separator: " ")
    if words.isEmpty || Self.compactText(timingText) != Self.compactText(result.text) {
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty
        ? [] : [makeSegment(chunk, index: 0, start: 0, end: chunk.track.duration, text: text)]
    }
    var segments: [Segment] = []
    var group: [WordTiming] = []
    func flush() {
      guard let first = group.first, let last = group.last else { return }
      var segment = makeSegment(
        chunk, index: segments.count, start: first.startTime, end: last.endTime,
        text: group.map(\.word).joined(separator: " "))
      segment.captionWords = group.map {
        CaptionWord(
          text: $0.word, start: chunk.offset + $0.startTime,
          end: chunk.offset + $0.endTime, speaker: chunk.speaker)
      }
      segments.append(segment)
      group = []
    }
    for word in words {
      group.append(word)
      if let first = group.first,
        word.endTime - first.startTime >= 6 || word.word.hasSuffix(".") || word.word.hasSuffix("?")
      {
        flush()
      }
    }
    flush()
    return segments
  }
  private func makeSegment(
    _ chunk: CapturedChunk, index: Int, start: Double, end: Double, text: String
  ) -> Segment {
    Segment(
      id: "\(chunk.track.id):\(index)", start: chunk.offset + max(0, start),
      end: chunk.offset + max(start, end), speaker: chunk.speaker, rawText: text, text: text,
      status: "raw", revision: 0, corrections: [])
  }
}

struct FinalRecognitionPass: Sendable {
  var segments: [Segment]
  var warnings: [String]
  var coverageComplete: Bool = false
  var coverageVerified: Bool = false
  var alternatives: [RecognitionAlternative] = []
}
extension TranscriptionEngine {
  /// Re-recognition is a new version; the controller archives the previous
  /// observations before applying this result. All saved audio stays untouched.
  func reprocess(
    _ chunks: [CapturedChunk], output: URL, reduceFillers: Bool = false, shortenPauses: Bool? = nil,
    language: String? = nil,
    terms: [String] = [], identifySpeakers: Bool = true, reference: URL? = nil,
    progress: (@Sendable (String) async -> Void)? = nil
  ) async throws
    -> FinalRecognitionPass
  {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    let useWhisper = await finalRecognition.downloaded()
    var warnings: [String] = []
    if !useWhisper {
      try await prepare(download: false)
    } else if reduceFillers {
      do {
        try await prepare(download: false)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        warnings.append(
          "Filler recognition is unavailable; original audio will be retained: "
            + error.localizedDescription)
      }
    }
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let shorten = shortenPauses ?? !useWhisper
    var result: [Segment] = []
    var alternatives: [RecognitionAlternative] = []
    var coverageComplete = !chunks.isEmpty
    var coverageVerified = !chunks.isEmpty
    var referenceSamples: [Float]?
    if let reference {
      do {
        referenceSamples = try AudioPreparationModel.load(reference)
      } catch {
        warnings.append("Your reference voice could not be loaded: " + error.localizedDescription)
      }
    }
    let knownReferences = (try? voiceProfiles.references()) ?? []
    let knownNames = Set(knownReferences.map(\.speaker)).union(["You"])
    let speakerModelReady = await speakers.downloaded()
    let useSpeakers = identifySpeakers && speakerModelReady
    if identifySpeakers && !speakerModelReady {
      warnings.append("Speaker identification is unavailable until its local model is downloaded")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for (speaker, group) in Dictionary(grouping: chunks, by: \.speaker).sorted(by: {
      $0.key < $1.key
    }) {
      await progress?("Reconstructing " + speaker.lowercased())
      // Keep this capture source's canonical IDs separate even when diarization
      // assigns the same voice label in another simultaneous source.
      let sourceResultStart = result.count
      let sorted = group.sorted { $0.offset < $1.offset }
      var samples: [Float] = []
      for chunk in sorted {
        let part = try AudioPreparationModel.load(chunk.url)
        let offset = max(0, Int((chunk.offset * 16000).rounded()))
        guard offset + part.count <= 16000 * 7200 else {
          throw AsideError("Reprocess recordings of up to two hours at a time")
        }
        if samples.count < offset + part.count {
          samples.append(contentsOf: repeatElement(0, count: offset + part.count - samples.count))
        }
        samples.replaceSubrange(offset..<(offset + part.count), with: part)
      }
      var fillerRegions: [SpeechRegion] = []
      var originalParakeet: ASRResult?
      if reduceFillers, let manager {
        do {
          var firstDecoder = try TdtDecoderState()
          let first = try await manager.transcribe(samples, decoderState: &firstDecoder)
          originalParakeet = first
          fillerRegions = AudioPreparationModel.fillerRegions(
            from: buildWordTimings(from: first.tokenTimings ?? []))
        } catch {
          if Task.isCancelled { throw CancellationError() }
          if !useWhisper { throw error }
          warnings.append(
            "Filler recognition failed; original audio will be retained: "
              + error.localizedDescription)
        }
      }
      let conditioned =
        reduceFillers
        ? AudioPreparationModel.maskFillers(samples, regions: fillerRegions) : samples
      let prepared: PreparedAudio
      if shorten {
        prepared = try await audioPreparation.prepare(
          conditioned, profile: .init(normalize: false), allowDownload: false)
      } else {
        prepared = AudioPreparationModel.render(
          conditioned, regions: [], profile: .init(normalize: false, shortenSilences: false))
      }
      let name = RecordingExport.sourceName(speaker)
      func diagnostic<T: Encodable>(_ value: T, _ suffix: String) throws {
        let path = output.appendingPathComponent(name + "-" + suffix + ".json")
        try encoder.encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
      }
      try AudioPreparationModel.write(
        prepared.samples, to: output.appendingPathComponent(name + "-prepared.wav"))
      try encoder.encode(fillerRegions).write(
        to: output.appendingPathComponent(name + "-filler-regions.json"), options: .atomic)
      try encoder.encode(prepared.metrics).write(
        to: output.appendingPathComponent(name + "-metrics.json"), options: .atomic)
      try encoder.encode(prepared.timeMap).write(
        to: output.appendingPathComponent(name + "-time-map.json"), options: .atomic)
      var turns: [SpeakerTurn] = []
      var speechTurns: [SpeakerTurn] = []
      var acousticEvidenceAvailable = false
      await progress?("Checking original audio for speech")
      do {
        let regions = try await audioPreparation.speechRegions(samples, allowDownload: false)
        acousticEvidenceAvailable = true
        speechTurns = regions.map {
          SpeakerTurn(speaker: "Unknown speaker", start: $0.start, end: $0.end)
        }
        try encoder.encode(regions).write(
          to: output.appendingPathComponent(name + "-speech-regions.json"), options: .atomic)
      } catch {
        if Task.isCancelled { throw CancellationError() }
        warnings.append("Acoustic speech coverage: " + error.localizedDescription)
      }
      if useSpeakers {
        await progress?("Identifying voices")
        do {
          let analysis = try await speakers.analyze(
            samples, reference: referenceSamples, references: knownReferences)
          speechTurns.append(contentsOf: analysis.turns)
          acousticEvidenceAvailable = acousticEvidenceAvailable || !analysis.turns.isEmpty
          turns = analysis.turns
          try encoder.encode(analysis).write(
            to: output.appendingPathComponent(name + "-speakers.json"), options: .atomic)
          if referenceSamples != nil, !analysis.referenceMatched {
            warnings.append(
              "Your reference voice was not confidently matched in " + speaker.lowercased())
          }
        } catch {
          if Task.isCancelled { throw CancellationError() }
          warnings.append("Speaker identification: " + error.localizedDescription)
        }
      }
      func appendPassages(_ originalPassages: [WhisperPassage]) throws {
        let coverage = RecognitionCoverage.assess(
          passages: originalPassages, speech: speechTurns,
          duration: Double(samples.count) / 16000,
          evidenceAvailable: acousticEvidenceAvailable)
        try diagnostic(originalPassages, "recognition-merged")
        try diagnostic(coverage, "coverage-final")
        coverageVerified = coverageVerified && coverage.verified
        coverageComplete = coverageComplete && coverage.complete
        if !coverage.timingIssues.isEmpty {
          warnings.append(
            "Some words in " + speaker.lowercased()
              + " could not be assigned confidently to a voice. Recognized wording was retained."
          )
        }
        if !coverage.verified {
          warnings.append(
            "Speech coverage could not be verified in " + speaker.lowercased()
              + "; available wording was retained")
        } else if !coverage.complete {
          let intervals = coverage.gaps.prefix(8).map {
            String(Int($0.start)) + "–" + String(Int($0.end)) + "s"
          }.joined(separator: ", ")
          warnings.append("Unresolved recognized-speech coverage gaps: " + intervals)
        }
        let attributed =
          turns.isEmpty
          ? originalPassages.map {
            AttributedPassage(speaker: speaker, text: $0.text, start: $0.start, end: $0.end)
          }
          : SpeakerAttribution.align(originalPassages, turns: turns)
        let passID = newID()
        for passage in attributed {
          let label =
            knownNames.contains(passage.speaker) || turns.isEmpty
            ? passage.speaker : speaker + " · " + passage.speaker
          result.append(
            Segment(
              id: "reprocessed-" + passID + ":" + String(result.count),
              start: passage.start, end: passage.end, speaker: label, rawText: passage.text,
              text: passage.text, status: "raw", revision: 0, corrections: []))
        }
      }
      if useWhisper {
        await progress?("Recognizing saved audio")
        // At the pinned WhisperKit revision, vocabulary prompts trigger first-token
        // aborts and corrupt word alignment (311 -> 52 words on a matched audio crop).
        // Keep glossary context in the language agent; acoustic decoding stays unprompted.
        let passages = try await finalRecognition.transcribe(
          prepared.samples, language: language, words: true,
          progress: { fraction in
            Task {
              await progress?("Recognizing saved audio · " + String(Int(fraction * 100)) + "%")
            }
          })
        var originalPassages = Self.originalTimeline(passages, prepared: prepared)
        let duration = Double(samples.count) / 16000
        try diagnostic(originalPassages, "recognition-initial")
        try diagnostic(
          RecognitionCoverage.assess(
            passages: originalPassages, speech: speechTurns, duration: duration,
            evidenceAvailable: acousticEvidenceAvailable), "coverage-initial")
        let unreliable = originalPassages.filter {
          let assessment = RecognitionCoverage.assess(
            passages: [$0], speech: speechTurns, duration: duration,
            evidenceAvailable: acousticEvidenceAvailable)
          return !assessment.verified && !assessment.timingIssues.isEmpty
        }
        for (index, candidate) in unreliable.prefix(8).enumerated() {
          guard candidate.start >= 0, candidate.end <= duration,
            candidate.end > candidate.start, candidate.end - candidate.start <= 22,
            RecognitionCoverage.retryEligible(
              RecognitionGap(
                start: candidate.start, end: candidate.end,
                speechSeconds: candidate.end - candidate.start),
              speech: speechTurns),
            let position = originalPassages.firstIndex(where: {
              $0.start == candidate.start && $0.end == candidate.end && $0.text == candidate.text
            })
          else { continue }
          await progress?("Checking uncertain word timing against original audio")
          let lower = max(0, Int(((candidate.start - 1.5) * 16000).rounded(.down)))
          let upper = min(samples.count, Int(((candidate.end + 1.5) * 16000).rounded(.up)))
          do {
            try Task.checkCancellation()
            let retry = try await finalRecognition.transcribe(
              Array(samples[lower..<upper]), language: language, words: true,
              firstTokenLogProbThreshold: nil, temperatureFallbackCount: 0)
            let shifted = RecognitionCoverage.shifted(retry, by: Double(lower) / 16000)
            try diagnostic(shifted, "recognition-timing-retry-" + String(index + 1))
            var replacement = RecognitionCoverage.replacingUnreliableCandidate(
              originalPassages, at: position, with: shifted, speech: speechTurns, duration: duration
            )
            if replacement == nil, AsrModels.modelsExist(at: modelDirectory) {
              await progress?("Checking uncertain timing with Parakeet")
              let fallback = try await parakeetAlternative(Array(samples[lower..<upper]))
              let shiftedFallback = RecognitionCoverage.shifted(fallback, by: Double(lower) / 16000)
              try diagnostic(shiftedFallback, "recognition-timing-parakeet-" + String(index + 1))
              replacement = RecognitionCoverage.replacingUnreliableCandidate(
                originalPassages, at: position, with: shiftedFallback,
                speech: speechTurns, duration: duration)
            }
            try diagnostic(
              replacement != nil, "recognition-timing-retry-" + String(index + 1) + "-accepted")
            if let replacement {
              originalPassages = replacement
              try diagnostic(originalPassages, "recognition-merged")
            }
          } catch {
            if Task.isCancelled { throw CancellationError() }
            warnings.append("Word-timing recovery: " + error.localizedDescription)
          }
        }
        let gaps = RecognitionCoverage.gaps(
          passages: originalPassages, speech: speechTurns, duration: duration)
        if !gaps.isEmpty {
          await progress?("Recovering speech omitted by final recognition")
          // Re-decode original audio in windows shorter than Whisper's 30s
          // context. Work is bounded even if diarization or ASR is very poor.
          var remainingWindows = 12
          for gap in gaps {
            var cursor = gap.start
            while cursor < gap.end && remainingWindows > 0 {
              try Task.checkCancellation()
              let upper = min(gap.end, cursor + 22)
              let start = max(0, cursor - 1.5)
              let end = min(duration, upper + 1.5)
              let lowerSample = max(0, Int((start * 16000).rounded(.down)))
              let upperSample = min(samples.count, Int((end * 16000).rounded(.up)))
              let window = Array(samples[lowerSample..<upperSample])
              let interval = RecognitionGap(
                start: cursor, end: upper, speechSeconds: upper - cursor)
              guard RecognitionCoverage.retryEligible(interval, speech: speechTurns) else {
                cursor = upper
                continue
              }
              do {
                // Keep speech-supported retries deterministic and avoid the
                // decoder's early first-token abort, as in the initial pass.
                let retry = try await finalRecognition.transcribe(
                  window, language: language, words: true,
                  firstTokenLogProbThreshold: nil, temperatureFallbackCount: 0)
                let shifted = RecognitionCoverage.shifted(retry, by: Double(lowerSample) / 16000)
                try diagnostic(shifted, "recognition-retry-" + String(13 - remainingWindows))
                originalPassages = RecognitionCoverage.merge(
                  original: originalPassages, repairs: shifted, gaps: [interval],
                  speech: speechTurns)
                try diagnostic(originalPassages, "recognition-merged")
              } catch {
                if Task.isCancelled { throw CancellationError() }
                warnings.append("Speech recovery: " + error.localizedDescription)
              }
              remainingWindows -= 1
              cursor = upper
            }
          }
          let unresolved = RecognitionCoverage.gaps(
            passages: originalPassages, speech: speechTurns, duration: duration)
          if !unresolved.isEmpty, AsrModels.modelsExist(at: modelDirectory) {
            await progress?("Checking omitted speech with Parakeet")
            try await prepare(download: false)
            if let manager {
              for (index, gap) in unresolved.prefix(12).enumerated() {
                guard RecognitionCoverage.retryEligible(gap, speech: speechTurns) else { continue }
                // Bound fallback cost, and leave any remainder explicitly unresolved.
                let start = max(0, gap.start - 1)
                let end = min(duration, min(gap.end, gap.start + 22) + 1)
                let lower = max(0, Int((start * 16000).rounded(.down)))
                let upper = min(samples.count, Int((end * 16000).rounded(.up)))
                do {
                  var decoder = try TdtDecoderState()
                  let retry = try await manager.transcribe(
                    Array(samples[lower..<upper]), decoderState: &decoder)
                  let words = buildWordTimings(from: retry.tokenTimings ?? [])
                  let repair = WhisperPassage(
                    text: retry.text, start: 0, end: Double(upper - lower) / 16000,
                    words: words.map {
                      WhisperWord(text: $0.word, start: $0.startTime, end: $0.endTime)
                    })
                  let shifted = RecognitionCoverage.shifted([repair], by: Double(lower) / 16000)
                  try diagnostic(shifted, "recognition-parakeet-fallback-" + String(index + 1))
                  originalPassages = RecognitionCoverage.merge(
                    original: originalPassages, repairs: shifted, gaps: [gap], speech: speechTurns)
                  try diagnostic(originalPassages, "recognition-merged")
                } catch {
                  if Task.isCancelled { throw CancellationError() }
                  warnings.append("Parakeet speech recovery: " + error.localizedDescription)
                }
              }
            }
          }
          let remaining = RecognitionCoverage.gaps(
            passages: originalPassages, speech: speechTurns, duration: duration)
          if remaining.isEmpty {
            warnings.append("Recovered speech that the first final-recognition pass omitted")

          }
        }
        try appendPassages(originalPassages)
        if AsrModels.modelsExist(at: modelDirectory) {
          await progress?("Recognizing independent Parakeet evidence from original audio")
          do {
            try Task.checkCancellation()
            let secondary: ASRResult
            if let originalParakeet {
              secondary = originalParakeet
            } else {
              try await prepare(download: false)
              guard let manager else { throw AsideError("Independent speech model unavailable") }
              var decoder = try TdtDecoderState()
              // Use the original meeting clock. The SDK handles long inputs via
              // ChunkProcessor; conditioning or Whisper wording never enters here.
              secondary = try await manager.transcribe(samples, decoderState: &decoder)
            }
            var evidence = Self.parakeetEvidencePassages(
              text: secondary.text,
              words: buildWordTimings(from: secondary.tokenTimings ?? []), duration: duration)
            if !evidence.timingsMatched, !evidence.passages.isEmpty {
              warnings.append(
                "Some independent Parakeet word timing in " + speaker.lowercased()
                  + " is uncertain; bounded audio windows preserve local context.")
              if duration > 30 {
                // A whole-meeting untimed hypothesis cannot be attached to every
                // later passage: its early wording would masquerade as local evidence.
                // Re-decode bounded original audio with halos instead. Overlapping
                // hearings remain distinct alternatives, never concatenated speech.
                try diagnostic(secondary, "recognition-parakeet-original-result")
                var local: [WhisperPassage] = []
                var cursor = 0.0
                while cursor < duration {
                  try Task.checkCancellation()
                  let lower = max(0, Int((max(0, cursor - 2) * 16000).rounded(.down)))
                  let upper = min(
                    samples.count, Int((min(duration, cursor + 26) * 16000).rounded(.up)))
                  let window = Array(samples[lower..<upper])
                  let retry = try await parakeetAlternative(window)
                  let split = Self.parakeetEvidencePassages(
                    text: retry.map(\.text).joined(separator: " "),
                    words: (retry.flatMap { $0.words ?? [] }).map {
                      WordTiming(word: $0.text, startTime: $0.start, endTime: $0.end)
                    }, duration: Double(window.count) / 16000)
                  local += RecognitionCoverage.shifted(split.passages, by: Double(lower) / 16000)
                  cursor += 24
                }
                evidence.passages = local
              }
            }
            let mapped = Self.mapRecognitionAlternatives(
              evidence.passages, sourceSegments: Array(result[sourceResultStart...]))
            alternatives.append(contentsOf: mapped)
            if mapped.isEmpty {
              warnings.append(
                "Independent Parakeet recognition returned no wording for " + speaker.lowercased())
            } else if mapped.contains(where: { $0.sourceIDs.isEmpty }) {
              warnings.append(
                "Some independent Parakeet wording in " + speaker.lowercased()
                  + " has no overlapping canonical passage; it remains separate evidence.")
            }
            try diagnostic(secondary, "recognition-parakeet-original-result")
            try diagnostic(evidence.passages, "recognition-parakeet-original")
            try diagnostic(mapped, "recognition-alternatives")
          } catch {
            if Task.isCancelled { throw CancellationError() }
            warnings.append("Independent Parakeet evidence: " + error.localizedDescription)
          }
        }
        continue
      }
      guard let manager else { throw AsideError("Speech model unavailable") }
      var decoder = try TdtDecoderState()
      let recognized = try await manager.transcribe(prepared.samples, decoderState: &decoder)
      let words = buildWordTimings(from: recognized.tokenTimings ?? [])
      var groupWords: [WordTiming] = []
      var passages: [WhisperPassage] = []
      func flush() {
        guard let first = groupWords.first, let last = groupWords.last else { return }
        passages.append(
          WhisperPassage(
            text: groupWords.map(\.word).joined(separator: " "),
            start: first.startTime, end: last.endTime,
            words: groupWords.map {
              WhisperWord(text: $0.word, start: $0.startTime, end: $0.endTime)
            }))
        groupWords = []
      }
      if words.isEmpty, !recognized.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        passages.append(
          WhisperPassage(
            text: recognized.text, start: 0, end: Double(prepared.samples.count) / 16000))
      }
      for word in words {
        groupWords.append(word)
        if let first = groupWords.first,
          word.endTime - first.startTime > 15 || word.word.hasSuffix(".")
            || word.word.hasSuffix("?")
        {
          flush()
        }
      }
      flush()
      // Token timing is optional metadata, not permission to lose ASR text.
      if Self.compactText(passages.map(\.text).joined(separator: " "))
        != Self.compactText(recognized.text)
      {
        passages = [
          WhisperPassage(
            text: recognized.text, start: 0, end: Double(prepared.samples.count) / 16000,
            words: words.map {
              WhisperWord(text: $0.word, start: $0.startTime, end: $0.endTime)
            })
        ]
      }
      let originalPassages = Self.originalTimeline(passages, prepared: prepared)
      try diagnostic(originalPassages, "recognition-initial")
      try diagnostic(
        RecognitionCoverage.assess(
          passages: originalPassages, speech: speechTurns, duration: Double(samples.count) / 16000,
          evidenceAvailable: acousticEvidenceAvailable), "coverage-initial")
      try appendPassages(originalPassages)
    }
    return FinalRecognitionPass(
      segments: result.sorted { $0.start < $1.start }, warnings: warnings,
      coverageComplete: coverageComplete, coverageVerified: coverageVerified,
      alternatives: alternatives)
  }
}

extension TranscriptionEngine {
  /// Word timing can partition raw text only when it covers that text faithfully.
  /// Short unmatched windows retain their full text without invented word ownership.
  /// The caller re-decodes long unmatched recordings as bounded original-audio windows.
  static func parakeetEvidencePassages(
    text: String, words: [WordTiming], duration: Double
  ) -> (passages: [WhisperPassage], timingsMatched: Bool) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return ([], false)
    }
    let timingsMatched =
      !words.isEmpty
      && words.map(\.word).joined(separator: " ").lowercased().filter { $0.isLetter || $0.isNumber }
        == text.lowercased().filter { $0.isLetter || $0.isNumber }
      && words.allSatisfy {
        $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0
          && $0.endTime >= $0.startTime && $0.endTime <= duration
          && $0.endTime - $0.startTime <= 15
      }
      && zip(words, words.dropFirst()).allSatisfy { previous, next in
        next.startTime >= previous.startTime
      }
    guard timingsMatched else {
      return ([WhisperPassage(text: text, start: 0, end: duration, words: [])], false)
    }
    var passages: [WhisperPassage] = []
    var group: [WordTiming] = []
    func flush() {
      guard let first = group.first, let last = group.last else { return }
      passages.append(
        WhisperPassage(
          text: group.map(\.word).joined(separator: " "),
          start: first.startTime, end: last.endTime,
          words: group.map { WhisperWord(text: $0.word, start: $0.startTime, end: $0.endTime) }))
      group = []
    }
    for word in words {
      if let first = group.first, word.endTime - first.startTime > 15 { flush() }
      group.append(word)
      if word.word.hasSuffix(".") || word.word.hasSuffix("?") || word.word.hasSuffix("!") {
        flush()
      }
    }
    flush()
    return (passages, true)
  }

  /// The caller supplies only the canonical slice just produced for one capture.
  /// Matching by voice label would mix simultaneous microphone/system captures.
  static func mapRecognitionAlternatives(
    _ passages: [WhisperPassage], sourceSegments: [Segment]
  ) -> [RecognitionAlternative] {
    passages.map { passage in
      RecognitionAlternative(
        id: "parakeet-original-" + newID(), model: "Parakeet TDT v3 · original audio",
        sourceIDs: sourceSegments.filter {
          max($0.start, passage.start) < min($0.end, passage.end)
        }.map(\.id),
        start: passage.start, end: passage.end, text: passage.text,
        words: (passage.words ?? []).map {
          RecognitionAlternativeWord(text: $0.text, start: $0.start, end: $0.end)
        })
    }
  }

  private func parakeetAlternative(_ samples: [Float]) async throws -> [WhisperPassage] {
    try await prepare(download: false)
    guard let manager else { throw AsideError("Speech model unavailable") }
    var decoder = try TdtDecoderState()
    let recognized = try await manager.transcribe(samples, decoderState: &decoder)
    let words = buildWordTimings(from: recognized.tokenTimings ?? [])
    return [
      WhisperPassage(
        text: recognized.text, start: 0, end: Double(samples.count) / 16000,
        words: words.map { WhisperWord(text: $0.word, start: $0.startTime, end: $0.endTime) })
    ]
  }

  private static func compactText(_ text: String) -> String {
    String(text.filter { !$0.isWhitespace })
  }

  /// A cut has two source times: the preceding end and the following start.
  /// Preserve that distinction so a word ending at a splice cannot gain the
  /// entire removed pause (and accidentally become another speaker's word).
  static func originalTimeline(_ passages: [WhisperPassage], prepared: PreparedAudio)
    -> [WhisperPassage]
  {
    func original(_ time: Double, end: Bool) -> Double {
      if end,
        let span = prepared.timeMap.last(where: {
          time > $0.outputStart && time <= $0.outputEnd
        })
      {
        return span.sourceStart
          + min(max(0, time - span.outputStart), span.sourceEnd - span.sourceStart)
      }
      return prepared.originalTime(time)
    }
    return passages.map { passage in
      WhisperPassage(
        text: passage.text, start: original(passage.start, end: false),
        end: original(passage.end, end: true),
        words: passage.words?.map {
          WhisperWord(
            text: $0.text, start: original($0.start, end: false), end: original($0.end, end: true))
        })
    }
  }
}

extension TranscriptionEngine {
  /// A second hearing of recent, already captured audio. Captions keep flowing
  /// through their own streaming session while Whisper and voice clustering run.
  /// No glossary prompt, final transcript or future audio enters recognition.
  func recognizeLiveWindow(
    _ chunks: [CapturedChunk], segments: [Segment], language: String?,
    identifySpeakers: Bool, reference: URL?
  ) async throws -> LiveRecognitionPass {
    let use = modelOwnership.beginUse()
    defer { modelOwnership.endUse(use) }
    var result = LiveRecognitionPass()
    let useWhisper = liveWhisperReady
    let knownReferences = (try? voiceProfiles.references()) ?? []
    let knownNames = Set(knownReferences.map(\.speaker)).union(["You"])
    let useSpeakers =
      identifySpeakers && (reference != nil || !knownReferences.isEmpty) && liveSpeakersReady
    if !useWhisper && !useSpeakers { return result }
    let referenceSamples = try reference.map { try AudioPreparationModel.load($0) }
    for (source, group) in Dictionary(grouping: chunks, by: \.speaker).sorted(by: {
      $0.key < $1.key
    }) {
      try Task.checkCancellation()
      let end = group.map { $0.offset + $0.track.duration }.max() ?? 0
      let start = max(group.map(\.offset).min() ?? 0, end - 60)
      guard end > start else { continue }
      var samples = [Float](repeating: 0, count: Int(((end - start) * 16000).rounded()))
      for chunk in group where chunk.offset + chunk.track.duration > start {
        let audio = try AudioPreparationModel.load(chunk.url)
        let position = Int(((chunk.offset - start) * 16000).rounded())
        let skip = max(0, -position)
        let lower = max(0, position)
        let count = min(audio.count - skip, samples.count - lower)
        if count > 0 {
          samples.replaceSubrange(lower..<(lower + count), with: audio[skip..<(skip + count)])
        }
      }
      var turns: [SpeakerTurn] = []
      if useSpeakers {
        do {
          turns = try await speakers.analyze(
            samples, reference: referenceSamples, references: knownReferences
          ).turns
          // Named enrolled voices carry across windows; anonymous cluster
          // numbers still belong only to the current acoustic window.
          turns = turns.map {
            SpeakerTurn(
              speaker: Array(
                Set(
                  $0.speaker.components(separatedBy: " + ").map {
                    knownNames.contains($0) ? $0 : source
                  })
              ).sorted().joined(separator: " + "),
              start: $0.start, end: $0.end)
          }
          let trackIDs = Set(group.map { $0.track.id })
          let words = Self.liveCaptionWordAssignments(
            segments: segments, turns: turns, offset: start, windowEnd: end, trackIDs: trackIDs)
          result.captionWordAssignments.merge(words, uniquingKeysWith: { _, latest in latest })
          // Older saved captions may have no word timing. Preserve their existing
          // positive-overlap fallback; new captions are attributed word by word.
          result.speakerAssignments.merge(
            Self.liveSpeakerAssignments(
              segments: segments.filter { $0.captionWords?.isEmpty != false },
              turns: turns, offset: start, trackIDs: trackIDs),
            uniquingKeysWith: { _, latest in latest })
          for (id, attributed) in words {
            let labels = Set(attributed.map { $0.speaker ?? source })
            result.speakerAssignments[id] = labels.count == 1 ? labels.first! : "Mixed speakers"
          }
        } catch {
          if Task.isCancelled { throw CancellationError() }
          result.warnings.append("Live voice identification: " + error.localizedDescription)
        }
      }
      if useWhisper {
        do {
          let heard = try await finalRecognition.transcribe(
            samples, language: language, words: true)
          let passages =
            turns.isEmpty
            ? heard.map {
              AttributedPassage(speaker: source, text: $0.text, start: $0.start, end: $0.end)
            }
            : SpeakerAttribution.align(heard, turns: turns)
          for passage in passages {
            let lo = start + passage.start
            let hi = start + passage.end
            let ids = segments.filter { segment in
              segment.end > lo && segment.start < hi
                && group.contains { segment.id.hasPrefix($0.track.id + ":") }
            }.map(\.id)
            result.alternatives.append(
              RecognitionAlternative(
                id: "whisper-live-" + newID(), model: "Whisper large-v3 turbo · live window",
                sourceIDs: ids, start: lo, end: hi, text: passage.text, words: [],
                speaker: passage.speaker))
          }
        } catch {
          if Task.isCancelled { throw CancellationError() }
          result.warnings.append("Live second recognition: " + error.localizedDescription)
        }
      }
    }
    return result
  }
  /// Keep measured word boundaries when a stable caption spans a voice change.
  /// Boundary words retain their previous labels instead of inheriting an
  /// identity from the fraction of the word inside this acoustic window.
  static func liveCaptionWordAssignments(
    segments: [Segment], turns: [SpeakerTurn], offset: Double, windowEnd: Double,
    trackIDs: Set<String>
  ) -> [String: [CaptionWord]] {
    guard offset.isFinite, windowEnd.isFinite, windowEnd > offset else { return [:] }
    let absolute = turns.map {
      SpeakerTurn(speaker: $0.speaker, start: offset + $0.start, end: offset + $0.end)
    }
    var result: [String: [CaptionWord]] = [:]
    for segment in segments
    where segment.status != "manual" && !segment.isNote && segment.text == segment.rawText
      && trackIDs.contains(where: { segment.id.hasPrefix($0 + ":") })
    {
      guard var words = segment.captionWords, !words.isEmpty else { continue }
      var attributed = false
      for i in words.indices {
        guard words[i].start.isFinite, words[i].end.isFinite,
          words[i].start >= offset, words[i].end <= windowEnd,
          words[i].end >= words[i].start
        else { continue }
        words[i].speaker = SpeakerAttribution.speaker(
          start: words[i].start, end: words[i].end, turns: absolute)
        attributed = true
      }
      if attributed { result[segment.id] = words }
    }
    return result
  }
  static func liveSpeakerAssignments(
    segments: [Segment], turns: [SpeakerTurn], offset: Double, trackIDs: Set<String>
  ) -> [String: String] {
    var assignments: [String: String] = [:]
    for segment in segments where trackIDs.contains(where: { segment.id.hasPrefix($0 + ":") }) {
      var overlap: [String: Double] = [:]
      for turn in turns {
        let seconds = min(segment.end, offset + turn.end) - max(segment.start, offset + turn.start)
        // Zero overlap must not introduce a candidate name in a diarization gap.
        if seconds > 0 { overlap[turn.speaker, default: 0] += seconds }
      }
      if let name = overlap.max(by: { $0.value < $1.value })?.key {
        assignments[segment.id] = name
      }
    }
    return assignments
  }

}
