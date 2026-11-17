import { useSyncExternalStore } from "react"
import { manualCoveredSegmentIDs, refreshSpeakerNames, transcriptFingerprint } from "@/lib/document"
import type { AppState, DocumentRecord, Meeting, Runtime } from "@/lib/types"

type Payload = Record<string, unknown>
type Reply = {
  id?: string
  result?: unknown
  error?: string
  event?: string
  state?: AppState
  meetingID?: string
  duration?: number
  runtime?: Runtime
}
declare global {
  interface Window {
    webkit?: { messageHandlers?: { aside?: { postMessage: (message: unknown) => void } } }
    __asideReceive?: (reply: Reply) => void
  }
}
const storageKey = "aside-browser-workspace-v1"
const native = Boolean(window.webkit?.messageHandlers?.aside)
const emptyState: AppState = {
  meetings: [],
  meeting: null,
  documents: [],
  glossary: [],
  settings: {
    provider: "claude-cli",
    assistantEnabled: true,
    captureSystemAudio: true,
    repairInterval: 30,
    anticipationInterval: 60,
    language: "auto",
  },
  runtime: {
    native,
    recording: false,
    modelStatus: "notDownloaded",
    modelMessage: "Parakeet · English and Spanish",
    assistantStatus: "idle",
    inputLevel: 0,
    systemLevel: 0,
    providerAvailable: false,
    totalCalls: 0,
    lastError: null,
  },
}
let current: AppState = emptyState
const browserMeetings = new Map<string, Meeting>()
if (!native) {
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey) ?? "null")
    if (saved?.state && Array.isArray(saved.meetings)) {
      current = { ...saved.state, runtime: emptyState.runtime }
      for (const meeting of saved.meetings) {
        refreshSpeakerNames(meeting)
        browserMeetings.set(meeting.id, meeting)
      }
      if (current.meeting) refreshSpeakerNames(current.meeting)
    }
  } catch {
    // A corrupt browser preview must not prevent the native app from opening.
  }
}
const listeners = new Set<() => void>()
const pending = new Map<
  string,
  {
    resolve: (value: unknown) => void
    reject: (error: Error) => void
    timer: number
    long: boolean
    narration: boolean
    progress: string
    arm: () => number
  }
>()
function publish(state: AppState) {
  current = state
  for (const listener of listeners) listener()
}
function isState(value: unknown): value is AppState {
  return typeof value === "object" && value !== null && "runtime" in value && "meetings" in value
}
window.__asideReceive = (reply) => {
  if (
    reply.event === "recordingTick" &&
    reply.meetingID &&
    reply.runtime &&
    typeof reply.duration === "number"
  ) {
    if (current.meeting?.id !== reply.meetingID || !current.runtime.recording) return
    // Preserve transcript/document references so the one-second clock does not rebuild prose.
    publish({
      ...current,
      runtime: reply.runtime,
      meeting:
        current.meeting?.id === reply.meetingID
          ? { ...current.meeting, duration: reply.duration }
          : current.meeting,
      meetings: current.meetings.map((meeting) =>
        meeting.id === reply.meetingID
          ? { ...meeting, duration: reply.duration as number }
          : meeting
      ),
    })
    return
  }
  if (reply.event === "state" && reply.state) {
    for (const request of pending.values()) {
      const progress = request.narration
        ? `${reply.state.runtime.narrationModelStatus ?? ""}|${reply.state.runtime.narrationMessage ?? ""}`
        : `${reply.state.runtime.assistantStatus}|${reply.state.meeting?.pendingStage ?? ""}|${reply.state.meeting?.document?.revision ?? ""}`
      if (request.long && request.progress !== progress) {
        request.progress = progress
        window.clearTimeout(request.timer)
        request.timer = request.arm()
      }
    }
    publish(reply.state)
  }
  if (!reply.id) return
  const request = pending.get(reply.id)
  if (!request) return
  pending.delete(reply.id)
  window.clearTimeout(request.timer)
  if (reply.error) request.reject(new Error(reply.error))
  else {
    if (isState(reply.result)) publish(reply.result)
    request.resolve(reply.result)
  }
}
export function useAside() {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    () => current
  )
}
export function request(action: string, payload: Payload = {}): Promise<unknown> {
  if (!native) return browserAction(action, payload)
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID()
    const narration = action === "prepareNarration" || action === "exportNarration"
    const long =
      narration ||
      [
        "downloadModel",
        "downloadFinalModel",
        "importAudio",
        "regenerateMemory",
        "exportAudio",
        "downloadSpeakerModel",
        "reprocessAudio",
        "runAssistant",
        "resumeProcessing",
        "identifySavedSpeakers",
      ].includes(action)
    const arm = () =>
      window.setTimeout(
        () => {
          pending.delete(id)
          reject(
            new Error(
              "This operation is taking longer than expected. Saved audio and transcripts are intact; check the processing status before retrying."
            )
          )
        },
        long ? 900_000 : 180_000
      )
    pending.set(id, { resolve, reject, timer: arm(), long, narration, progress: "", arm })
    window.webkit?.messageHandlers?.aside?.postMessage({ id, action, payload })
  })
}
function requireMeeting(): Meeting {
  if (!current.meeting) throw new Error("Create or choose a meeting first.")
  return current.meeting
}
function saveBrowser() {
  if (current.meeting) {
    refreshSpeakerNames(current.meeting)
    current.meeting.updatedAt = new Date().toISOString()
    browserMeetings.set(current.meeting.id, current.meeting)
  }
  const meetings = [...browserMeetings.values()].sort((a, b) =>
    b.createdAt.localeCompare(a.createdAt)
  )
  current = {
    ...current,
    meetings: meetings.map((meeting) => ({
      id: meeting.id,
      title: meeting.title,
      createdAt: meeting.createdAt,
      duration: meeting.duration,
      status: meeting.status,
      segmentCount: meeting.segments.length,
    })),
  }
  localStorage.setItem(storageKey, JSON.stringify({ state: current, meetings }))
  publish(current)
}
function download(name: string, text: string, type: string) {
  const url = URL.createObjectURL(new Blob([text], { type }))
  const a = document.createElement("a")
  a.href = url
  a.download = name
  a.click()
  window.setTimeout(() => URL.revokeObjectURL(url), 1000)
}
async function pickBrowserDocuments() {
  return new Promise<void>((resolve, reject) => {
    const input = document.createElement("input")
    input.type = "file"
    input.multiple = true
    input.accept = ".txt,.md,.markdown"
    input.addEventListener("cancel", () => resolve(), { once: true })
    input.addEventListener(
      "change",
      async () => {
        try {
          for (const file of input.files ?? []) {
            if (file.size > 10_000_000) throw new Error("Choose documents smaller than 10 MB.")
            const text = await file.text()
            const record: DocumentRecord = {
              id: crypto.randomUUID(),
              name: file.name,
              kind: file.name.split(".").pop() ?? "txt",
              characters: text.length,
              addedAt: new Date().toISOString(),
            }
            current.documents.push(record)
            if (current.meeting) current.meeting.documentIDs.push(record.id)
            localStorage.setItem(`aside-document-${record.id}`, text)
          }
          resolve()
        } catch (error) {
          reject(error)
        }
      },
      { once: true }
    )
    input.click()
  })
}
async function browserAction(action: string, payload: Payload): Promise<unknown> {
  switch (action) {
    case "getState":
      return current
    case "renameSpeaker": {
      const id = String(payload.meetingID ?? "")
      const meeting = current.meeting?.id === id ? current.meeting : browserMeetings.get(id)
      if (!meeting) throw new Error("Meeting not found")
      const speaker = String(payload.speaker ?? "")
      const name = String(payload.name ?? "").trim()
      meeting.speakerNames = { ...meeting.speakerNames }
      if (name) meeting.speakerNames[speaker] = name
      else delete meeting.speakerNames[speaker]
      refreshSpeakerNames(meeting)
      break
    }
    case "inspectTranscriptSource": {
      const meeting = requireMeeting()
      const source = payload.source as import("@/lib/types").Source
      if (source.meetingID !== meeting.id || !source.excerpt)
        throw new Error("Choose the citation's meeting first.")
      const matches = (text: string) =>
        text.split(/\s+/).join(" ").includes(source.excerpt.split(/\s+/).join(" "))
      if (source.segmentID) {
        const segment = meeting.segments.find(
          (value) => value.id === source.segmentID && matches(value.text)
        )
        if (segment) {
          const stamped = source.segmentRevision !== undefined
          const currentVersion = stamped
            ? source.segmentRevision === segment.revision
            : segment.revision === 0 && segment.corrections.length === 0
          const superseded =
            meeting.document && manualCoveredSegmentIDs(meeting.document).has(segment.id)
          if (currentVersion)
            return {
              meetingID: meeting.id,
              title: source.title,
              location: source.location,
              excerpt: source.excerpt,
              text: segment.text,
              rawText: segment.rawText,
              current: !superseded,
              revision: superseded
                ? "Recognition superseded by your document edit"
                : "Current recognition",
            }
          for (const correction of [...segment.corrections].reverse()) {
            const prior =
              source.segmentRevision === correction.beforeRevision
                ? correction.before
                : source.segmentRevision === correction.afterRevision
                  ? correction.after
                  : undefined
            if (prior && matches(prior))
              return {
                meetingID: meeting.id,
                title: source.title,
                location: source.location,
                excerpt: source.excerpt,
                text: prior,
                current: false,
                revision: "Earlier passage revision",
              }
          }
          if (!stamped)
            return {
              meetingID: meeting.id,
              title: source.title,
              location: source.location,
              excerpt: source.excerpt,
              text: source.excerpt,
              current: false,
              revision: "Saved quotation · passage version unverified",
            }
        }
      } else if (
        meeting.document &&
        meeting.document.revision === source.documentRevision &&
        matches(meeting.document.text)
      ) {
        return {
          meetingID: meeting.id,
          title: source.title,
          location: source.location,
          excerpt: source.excerpt,
          text: meeting.document.text.split(/\n\s*\n/).find(matches) ?? source.excerpt,
          current: true,
          revision: `Current document · revision ${source.documentRevision}`,
        }
      }
      throw new Error(
        "This quotation is not in the current transcript. Retained history is available in the native app."
      )
    }
    case "createMeeting": {
      const now = new Date().toISOString()
      current = {
        ...current,
        meeting: {
          id: crypto.randomUUID(),
          title: String(payload.title || "Untitled meeting"),
          titleIsAutomatic: !String(payload.title ?? "").trim(),
          context: String(payload.context ?? ""),
          startIncomplete: Boolean(payload.startIncomplete),
          language: (payload.language as Meeting["language"]) ?? current.settings.language,
          createdAt: now,
          updatedAt: now,
          status: "ready",
          duration: 0,
          documentIDs: [],
          segments: [],
          cards: [],
          messages: [],
          audioTracks: [],
        },
      }
      break
    }
    case "selectMeeting":
      current = { ...current, meeting: browserMeetings.get(String(payload.id)) ?? null }
      break
    case "renameMeeting": {
      const id = String(payload.id ?? "")
      const meeting = current.meeting?.id === id ? current.meeting : browserMeetings.get(id)
      const title = String(payload.title ?? "").trim()
      if (!meeting || !title) throw new Error("Enter a meeting name")
      meeting.title = title
      meeting.titleIsAutomatic = false
      break
    }
    case "updateMeeting": {
      const meeting = requireMeeting()
      if (typeof payload.title === "string" && payload.title !== meeting.title)
        meeting.titleIsAutomatic = false
      Object.assign(meeting, payload)
      break
    }
    case "copyText":
      await navigator.clipboard.writeText(String(payload.text ?? ""))
      return null
    case "editDocument": {
      const meeting = requireMeeting()
      const text = String(payload.text ?? "").trim()
      if (!text) throw new Error("Enter transcript text first.")
      if (payload.baseFingerprint !== transcriptFingerprint(meeting.segments))
        throw new Error("The transcript changed while you were editing. Your draft has been kept.")
      if ((meeting.document?.revision ?? 0) !== payload.revision)
        throw new Error("The document changed. Reopen it before saving.")
      if (meeting.document)
        meeting.documentHistory = [...(meeting.documentHistory ?? []), meeting.document]
      meeting.document = {
        text,
        sourceFingerprint: transcriptFingerprint(meeting.segments),
        revision: (meeting.document?.revision ?? 0) + 1,
        createdAt: new Date().toISOString(),
        author: "user",
      }
      break
    }
    case "addPassage": {
      const meeting = requireMeeting()
      const text = String(payload.text ?? "").trim()
      if (!text) throw new Error("Enter a passage first.")
      meeting.segments.push({
        id: crypto.randomUUID(),
        start: meeting.duration,
        end: meeting.duration,
        speaker: String(payload.speaker ?? "You"),
        rawText: text,
        text,
        status: "manual",
        kind: "note",
        revision: 0,
        corrections: [],
      })
      break
    }
    case "editSegment":
    case "revertSegment": {
      const segment = requireMeeting().segments.find((row) => row.id === payload.id)
      if (!segment) throw new Error("That passage is no longer available.")
      if (segment.revision !== payload.revision)
        throw new Error("The passage changed. Reopen it to edit.")
      const text = action === "revertSegment" ? segment.rawText : String(payload.text ?? "").trim()
      if (!text) throw new Error("The passage cannot be empty.")
      segment.corrections.push({
        id: crypto.randomUUID(),
        before: segment.text,
        after: text,
        reason: action === "revertSegment" ? "Restored original transcription" : "Your correction",
        createdAt: new Date().toISOString(),
      })
      segment.text = text
      segment.status = "manual"
      segment.revision += 1
      break
    }
    case "updateSettings":
      current = { ...current, settings: { ...current.settings, ...payload } }
      break
    case "addDocuments":
      await pickBrowserDocuments()
      break
    case "removeDocument":
      current.documents = current.documents.filter((doc) => doc.id !== payload.id)
      for (const meeting of browserMeetings.values()) {
        meeting.documentIDs = meeting.documentIDs.filter((id) => id !== payload.id)
      }
      if (current.meeting)
        current.meeting.documentIDs = current.meeting.documentIDs.filter((id) => id !== payload.id)
      localStorage.removeItem(`aside-document-${String(payload.id)}`)
      break
    case "learnCorrection": {
      const segment = requireMeeting().segments.find((row) => row.id === payload.segmentID)
      const term = String(payload.term ?? "").trim()
      const alias = String(payload.alias ?? "").trim()
      if (
        !segment ||
        segment.revision !== payload.revision ||
        segment.status !== "manual" ||
        !term ||
        !alias ||
        !segment.text.includes(term) ||
        !segment.corrections.some((change) => change.before.includes(alias))
      )
        throw new Error("Use wording from the saved correction.")
      if (current.glossary.some((entry) => entry.term.toLowerCase() === term.toLowerCase()))
        throw new Error("That term is already in your vocabulary. Your existing entry was kept.")
      current.glossary.push({
        id: crypto.randomUUID(),
        term,
        aliases: [alias],
        definition: String(payload.definition ?? ""),
        source: `Confirmed correction · ${requireMeeting().title}`,
      })
      break
    }
    case "addGlossary": {
      const term = String(payload.term ?? "").trim()
      if (!term) throw new Error("Enter a term first.")
      current.glossary.push({
        id: crypto.randomUUID(),
        term,
        aliases: Array.isArray(payload.aliases) ? payload.aliases.map(String) : [],
        definition: String(payload.definition ?? ""),
        source: "Added by you",
      })
      break
    }
    case "removeGlossary":
      current.glossary = current.glossary.filter((entry) => entry.id !== payload.id)
      break
    case "dismissCard": {
      const card = requireMeeting().cards.find((entry) => entry.id === payload.id)
      if (card) card.dismissed = true
      break
    }
    case "exportAudio":
      throw new Error("Audio exports are available in the Aside Mac app.")
    case "exportMeeting": {
      const meeting = requireMeeting()
      const name = meeting.title.replace(/[^a-zA-Z0-9 -]/g, "").trim() || "meeting"
      if (payload.format === "json")
        download(`${name}.json`, JSON.stringify(meeting, null, 2), "application/json")
      else {
        const text = `# ${meeting.title}\n\n${meeting.context}\n\n${meeting.segments.map((segment) => `**${segment.speaker}**\n\n${segment.text}`).join("\n\n")}\n\n## Original transcript\n\n${meeting.segments.map((segment) => segment.rawText).join("\n\n")}`
        download(`${name}.md`, text, "text/markdown")
      }
      return null
    }
    case "openSource": {
      const doc = current.documents.find((entry) => entry.id === payload.documentID)
      if (doc)
        download(doc.name, localStorage.getItem(`aside-document-${doc.id}`) ?? "", "text/plain")
      return null
    }
    case "clearError":
      current.runtime.lastError = null
      break
    default:
      throw new Error(
        action === "ask" || action === "runAssistant" || action === "extractGlossary"
          ? "The assistant runs in the Aside Mac app with your Claude Code or Codex login."
          : "Open the Aside Mac app to record, transcribe, and play audio locally."
      )
  }
  saveBrowser()
  return current
}
export function formatDuration(seconds: number): string {
  const value = Math.max(0, Math.floor(seconds))
  const minutes = Math.floor(value / 60)
  return `${minutes.toString().padStart(2, "0")}:${(value % 60).toString().padStart(2, "0")}`
}
