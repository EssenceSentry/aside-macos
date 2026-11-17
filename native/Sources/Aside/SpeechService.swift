import Foundation

struct LiveRecognitionPass: Sendable {
  var alternatives: [RecognitionAlternative] = []
  var speakerAssignments: [String: String] = [:]
  var captionWordAssignments: [String: [CaptionWord]] = [:]
  var warnings: [String] = []

  /// Apply acoustic metadata to the same immutable recognition observations.
  /// Capture can append new segments while a pass runs; IDs and original word
  /// geometry keep the completed pass scoped to the observations it actually heard.
  func applySpeakerAssignments(to segments: inout [Segment]) {
    for i in segments.indices where segments[i].status != "manual" && !segments[i].isNote {
      if let words = captionWordAssignments[segments[i].id] {
        guard segments[i].text == segments[i].rawText,
          let original = segments[i].captionWords, original.count == words.count,
          zip(original, words).allSatisfy({
            $0.text == $1.text && $0.start == $1.start && $0.end == $1.end
          })
        else { continue }
        segments[i].captionWords = words
      }
      if let speaker = speakerAssignments[segments[i].id] {
        segments[i].speaker = speaker
      }
    }
  }
}

/// Testable local-speech boundary; ordinary tests never load a real speech model.
protocol SpeechService: Sendable {
  func downloaded() async -> Bool
  func finalDownloaded() async -> Bool
  func speakersDownloaded() async -> Bool
  func prepare(download: Bool) async throws
  /// Best-effort memory retirement; false means release was skipped or unsupported.
  func releaseIdleModels() async -> Bool
  func prepareFinal(download: Bool) async throws
  func prepareSpeakers(download: Bool) async throws
  func prepareCoverage(download: Bool) async throws
  func makeLiveCaptionSession(
    source: String, generation: String,
    onUpdate: @escaping @Sendable (LiveCaptionSnapshot) async throws -> Void
  ) async throws -> (any LiveCaptionSession)?
  func transcribe(_ chunk: CapturedChunk) async throws -> [Segment]
  func recognizeLiveWindow(
    _ chunks: [CapturedChunk], segments: [Segment], language: String?,
    identifySpeakers: Bool, reference: URL?
  ) async throws -> LiveRecognitionPass
  func reprocess(
    _ chunks: [CapturedChunk], output: URL, reduceFillers: Bool, shortenPauses: Bool?,
    language: String?, terms: [String], identifySpeakers: Bool, reference: URL?,
    progress: (@Sendable (String) async -> Void)?
  ) async throws -> FinalRecognitionPass
}
extension SpeechService {
  func releaseIdleModels() async -> Bool { false }
  func recognizeLiveWindow(
    _ chunks: [CapturedChunk], segments: [Segment], language: String?,
    identifySpeakers: Bool, reference: URL?
  ) async throws -> LiveRecognitionPass { LiveRecognitionPass() }
  func makeLiveCaptionSession(
    source: String, generation: String,
    onUpdate: @escaping @Sendable (LiveCaptionSnapshot) async throws -> Void
  ) async throws -> (any LiveCaptionSession)? { nil }
}

extension TranscriptionEngine: SpeechService {}
