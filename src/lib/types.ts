export interface Source {
  documentID: string
  segmentID?: string
  meetingID?: string
  documentRevision?: number
  segmentRevision?: number
  title: string
  excerpt: string
  location: string
}
export interface Correction {
  id: string
  before: string
  after: string
  reason: string
  createdAt: string
  beforeRevision?: number
  afterRevision?: number
}
export interface CaptionWord {
  text: string
  start: number
  end: number
  speaker?: string
}
export interface Segment {
  captionWords?: CaptionWord[]
  kind?: string
  id: string
  start: number
  end: number
  speaker: string
  rawText: string
  text: string
  status: "raw" | "repaired" | "manual" | "uncertain"
  revision: number
  corrections: Correction[]
}
export interface AssistCard {
  id: string
  kind: "reference" | "question" | "reminder" | "answer"
  title: string
  body: string
  why: string
  sources: Source[]
  createdAt: string
  dismissed: boolean
  superseded?: boolean
}
export interface ChatMessage {
  id: string
  role: "user" | "assistant"
  text: string
  sources: Source[]
  createdAt: string
}
export interface ReadableBlock {
  id: string
  speaker: string
  sourceIDs: string[]
  text: string
  needsReview: boolean
}
export interface ReadableDocument {
  suggestedTitle?: string
  speakerNames?: Record<string, string>
  blocks?: ReadableBlock[]
  reviewNotes?: string[]
  text: string
  sourceFingerprint: string
  revision: number
  createdAt: string
  author: string
}
export interface CaptureIssue {
  source: "microphone" | "systemAudio"
  kind:
    | "writeFailed"
    | "sourceStopped"
    | "timestampGap"
    | "timestampOverlap"
    | "timestampUnavailable"
    | "formatChanged"
  offset: number
  duration: number
  message: string
}
export interface RecognitionDraft {
  id: string
  createdAt: string
  segments: Segment[]
  warnings: string[]
}
export interface Meeting {
  titleIsAutomatic?: boolean
  pendingStage?: "recognition" | "polish"
  processingError?: string
  startIncomplete?: boolean
  captureIssues?: CaptureIssue[]
  protectedPassTrackIDs?: string[]
  recognitionDraft?: RecognitionDraft
  recognitionNotice?: string
  speakerNotice?: string
  speakerNames?: Record<string, string>
  document?: ReadableDocument
  documentHistory?: ReadableDocument[]

  id: string
  title: string
  context: string
  language: "auto" | "en" | "es"
  createdAt: string
  updatedAt: string
  status: "ready" | "recording" | "processing" | "complete" | "interrupted"
  duration: number
  documentIDs: string[]
  segments: Segment[]
  cards: AssistCard[]
  messages: ChatMessage[]
  audioTracks: { id: string; label: string; filename: string; duration: number }[]
}
export interface MeetingSummary {
  id: string
  title: string
  createdAt: string
  duration: number
  status: Meeting["status"]
  segmentCount: number
}
export interface DocumentRecord {
  id: string
  name: string
  kind: string
  characters: number
  addedAt: string
}
export interface GlossaryEntry {
  id: string
  term: string
  aliases: string[]
  definition: string
  source: string
  sourceDocumentID?: string
}
export interface Settings {
  provider: "claude-cli" | "codex-cli"
  finalProvider?: "codex-terra" | "claude-cli" | "codex-cli"
  assistantEnabled: boolean
  captureSystemAudio: boolean
  shortenAudioPauses?: boolean
  reduceAudioFillers?: boolean
  identifySpeakers?: boolean
  contextualCaptions?: boolean
  workContext?: string
  repairInterval: number
  anticipationInterval: number
  language: "auto" | "en" | "es"
}
export interface Runtime {
  native: boolean
  contextFloating?: boolean
  assistantView?: "ready" | "ask"
  recording: boolean
  modelStatus: "notDownloaded" | "downloading" | "ready" | "error"
  modelMessage: string
  finalModelStatus?: string
  speakerModelStatus?: string
  voiceReferenceReady?: boolean
  narrationModelStatus?: "notDownloaded" | "downloading" | "ready" | "error"
  narrationMessage?: string
  captureHealth?: Record<string, "active" | "failed" | "stopped" | "warning">
  assistantStatus: string
  answering?: boolean
  inputLevel: number
  systemLevel: number
  providerAvailable: boolean
  finalProviderAvailable?: boolean
  totalCalls: number
  lastError: string | null
}
export interface VoiceProfileSample {
  id: string
  filename: string
  duration: number
  createdAt: string
  meetingID?: string
  speaker?: string
}
export interface VoiceProfile {
  id: string
  name: string
  enabled: boolean
  createdAt: string
  updatedAt: string
  samples: VoiceProfileSample[]
}
export interface AppState {
  meetings: MeetingSummary[]
  meeting: Meeting | null
  documents: DocumentRecord[]
  glossary: GlossaryEntry[]
  settings: Settings
  runtime: Runtime
  voiceProfiles?: VoiceProfile[]
  audioExports?: { label: string; preparedAvailable: boolean }[]
}

export interface TranscriptEvidence {
  meetingID: string
  title: string
  location: string
  excerpt: string
  text: string
  rawText?: string
  current: boolean
  revision: string
}
