import Foundation

func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
func newID() -> String { UUID().uuidString.lowercased() }

struct Source: Codable, Sendable, Equatable {
  var documentID: String
  var title: String
  var excerpt: String
  var location: String
  var segmentID: String? = nil
  var meetingID: String? = nil
  var documentRevision: Int? = nil
  var segmentRevision: Int? = nil
}
struct Correction: Codable, Sendable, Equatable {
  var id: String
  var before: String
  var after: String
  var reason: String
  var createdAt: String
  var beforeRevision: Int? = nil
  var afterRevision: Int? = nil
}
struct Segment: Codable, Sendable, Equatable {
  var id: String
  var start: Double
  var end: Double
  var speaker: String
  var rawText: String
  var text: String
  var status: String
  var revision: Int
  var corrections: [Correction]
  var captionWords: [CaptionWord]? = nil
  var kind: String? = nil
  var isNote: Bool {
    kind == "note" || (kind == nil && start == end && UUID(uuidString: id) != nil)
  }
}
struct AssistCard: Codable, Sendable, Equatable {
  var id: String
  var kind: String
  var title: String
  var body: String
  var why: String
  var sources: [Source]
  var createdAt: String
  var dismissed: Bool
  var superseded: Bool? = nil
}
struct ChatMessage: Codable, Sendable, Equatable {
  var id: String
  var role: String
  var text: String
  var sources: [Source]
  var createdAt: String
}
struct AudioTrack: Codable, Sendable, Equatable {
  var id: String
  var label: String
  var filename: String
  var duration: Double
}
struct PreparedRecording: Codable, Sendable, Equatable {
  var passID: String
  var trackIDs: [String]
  var timelineOffset: Double? = nil
}
struct AudioExportSource: Codable, Sendable {
  var label: String
  var preparedAvailable: Bool
}
enum MeetingProcessingStage: String, Codable, Sendable { case recognition, polish }
struct Meeting: Codable, Sendable, Equatable {
  var titleIsAutomatic: Bool? = nil
  var pendingStage: MeetingProcessingStage? = nil
  var processingError: String? = nil
  var startIncomplete: Bool? = nil
  var captureIssues: [CaptureIssue]? = nil
  var protectedPassTrackIDs: [String]? = nil
  var recognitionNotice: String? = nil
  var speakerNotice: String? = nil
  var speakerNames: [String: String]? = nil
  var preparedRecording: PreparedRecording? = nil
  var document: ReadableDocument? = nil
  var documentHistory: [ReadableDocument]? = nil
  var recognitionHistory: [RecognitionSnapshot]? = nil
  var recognitionDraft: RecognitionDraft? = nil
  var recognitionAlternatives: [RecognitionAlternative]? = nil
  var id: String
  var title: String
  var context: String
  var language: String
  var createdAt: String
  var updatedAt: String
  var status: String
  var duration: Double
  var documentIDs: [String]
  var segments: [Segment]
  var cards: [AssistCard]
  var messages: [ChatMessage]
  var audioTracks: [AudioTrack]
  static func make(title: String, context: String, language: String) -> Meeting {
    Meeting(
      id: newID(), title: title, context: context, language: language, createdAt: timestamp(),
      updatedAt: timestamp(), status: "ready", duration: 0, documentIDs: [], segments: [],
      cards: [], messages: [], audioTracks: [])
  }
  mutating func applySuggestedTitle() {
    guard titleIsAutomatic ?? (title == "Untitled meeting"),
      let suggestion = document?.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !suggestion.isEmpty
    else { return }
    title = suggestion
    titleIsAutomatic = true
  }
  var summary: MeetingSummary {
    MeetingSummary(
      id: id, title: title, createdAt: createdAt, duration: duration, status: status,
      segmentCount: segments.count)
  }
}
struct MeetingSummary: Codable, Sendable {
  var id: String
  var title: String
  var createdAt: String
  var duration: Double
  var status: String
  var segmentCount: Int
}
struct DocumentRecord: Codable, Sendable, Equatable {
  var id: String
  var name: String
  var kind: String
  var characters: Int
  var addedAt: String
}
struct GlossaryEntry: Codable, Sendable, Equatable {
  var id: String
  var term: String
  var aliases: [String]
  var definition: String
  var source: String
  var sourceDocumentID: String? = nil
}
struct Settings: Codable, Sendable {
  var provider = "claude-cli"
  var finalProvider: String? = nil
  var finalWriter: String { finalProvider ?? "codex-terra" }
  var assistantEnabled = true
  var captureSystemAudio = true
  var shortenAudioPauses: Bool? = nil
  var reduceAudioFillers: Bool? = nil
  var identifySpeakers: Bool? = nil
  var contextualCaptions: Bool? = nil
  var workContext: String? = nil
  var repairInterval: Double = 30
  var anticipationInterval: Double = 60
  var language = "auto"
}
struct RuntimeState: Codable, Sendable {
  var native = true
  var contextFloating: Bool? = nil
  var assistantView: String? = nil
  var recording = false
  var modelStatus = "notDownloaded"
  var modelMessage = "Parakeet TDT v3 · multilingual · download required"
  var finalModelStatus: String? = nil
  var speakerModelStatus: String? = nil
  var voiceReferenceReady: Bool? = nil
  var captureHealth: [String: String]? = nil
  var assistantStatus = "Assistant off"
  var answering: Bool? = nil
  var inputLevel: Double = 0
  var systemLevel: Double = 0
  var providerAvailable = false
  var finalProviderAvailable: Bool? = nil
  var narrationModelStatus: String? = nil
  var narrationMessage: String? = nil
  var totalCalls = 0
  var lastError: String?
}
struct AppState: Codable, Sendable {
  var meetings: [MeetingSummary]
  var meeting: Meeting?
  var documents: [DocumentRecord]
  var glossary: [GlossaryEntry]
  var settings: Settings
  var runtime: RuntimeState
  var audioExports: [AudioExportSource] = []
  var voiceProfiles: [VoiceProfile] = []
  enum CodingKeys: String, CodingKey {
    case meetings, meeting, documents, glossary, settings, runtime, audioExports, voiceProfiles
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(meetings, forKey: .meetings)
    // Full histories remain in the store and exports; the interface uses only current state.
    var visibleMeeting = meeting
    visibleMeeting?.recognitionHistory = nil
    visibleMeeting?.recognitionAlternatives = nil
    visibleMeeting?.documentHistory = nil
    try c.encode(visibleMeeting, forKey: .meeting)
    try c.encode(documents, forKey: .documents)
    try c.encode(glossary, forKey: .glossary)
    try c.encode(settings, forKey: .settings)
    try c.encode(runtime, forKey: .runtime)
    try c.encode(audioExports, forKey: .audioExports)
    try c.encode(voiceProfiles, forKey: .voiceProfiles)
  }
}
struct AsideError: LocalizedError {
  var message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
