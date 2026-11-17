import {
  ArrowDownToLine,
  ArrowRight,
  AudioLines,
  BookOpen,
  Check,
  CircleHelp,
  Clock3,
  Ellipsis,
  FileAudio,
  FileText,
  History,
  Languages,
  LoaderCircle,
  Mic,
  PenLine,
  PictureInPicture2,
  Plus,
  Search,
  Settings2,
  ShieldCheck,
  Sparkles,
  Square,
  Trash2,
  Upload,
  UsersRound,
  X,
} from "lucide-react"
import { type ReactNode, useCallback, useEffect, useRef, useState } from "react"
import { AppIcon } from "@/app-icon"
import { AppBar } from "@/blocks/app-bar"
import { ContextActions } from "@/blocks/context-actions"
import { ShortcutsHelp } from "@/blocks/keyboard"
import { Eyebrow } from "@/blocks/primitives"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { formatDuration, request, useAside } from "@/lib/bridge"
import { useKeys } from "@/lib/keys"
import type { GlossaryEntry, Segment, Source, TranscriptEvidence } from "@/lib/types"
import { cn } from "@/lib/utils"
import { AssistantPane } from "@/screens/assistant"
import {
  GlossaryForm,
  MeetingForm,
  NarrationExport,
  PassageForm,
  SettingsPanel,
  SpeakerNamesForm,
} from "@/screens/forms"
import { type Act, dateLabel, languageNames, Modal, type ModalName } from "@/screens/shared"
import { AudioLevel, EmptyTranscript, Transcript } from "@/screens/transcript"

type View = "meeting" | "documents" | "glossary"

export function MonitorScreen() {
  const state = useAside()
  const [view, setView] = useState<View>("meeting")
  const [modal, setModal] = useState<ModalName>(null)
  const [editing, setEditing] = useState<Segment | undefined>()
  const [raw, setRaw] = useState(false)
  const [audioSource, setAudioSource] = useState("")
  const [renamingMeeting, setRenamingMeeting] = useState<string | null>(null)
  const [meetingTitleDraft, setMeetingTitleDraft] = useState("")
  const [search, setSearch] = useState("")
  const [librarySearch, setLibrarySearch] = useState("")
  const [busy, setBusy] = useState(new Set<string>())
  const [error, setError] = useState<string | null>(null)
  const [undo, setUndo] = useState<GlossaryEntry | null>(null)
  const [evidence, setEvidence] = useState<TranscriptEvidence | null>(null)
  const evidenceRequest = useRef(0)
  const closeEvidence = useCallback(() => {
    evidenceRequest.current += 1
    setEvidence(null)
  }, [])
  const close = useCallback(() => {
    setModal(null)
    setEditing(undefined)
  }, [])
  const act = useCallback<Act>(async (action, payload = {}) => {
    setBusy((current) => new Set(current).add(action))
    try {
      await request(action, payload)
      setError(null)
      return true
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
      return false
    } finally {
      setBusy((current) => {
        const next = new Set(current)
        next.delete(action)
        return next
      })
    }
  }, [])
  useEffect(() => {
    void act("getState")
  }, [act])
  useEffect(() => {
    let active = true
    async function inspect(event: Event) {
      const source = (event as CustomEvent<Source>).detail
      if (source.meetingID !== state.meeting?.id) {
        setError("Choose the citation's meeting before opening this passage.")
        return
      }
      const token = ++evidenceRequest.current
      setEvidence(null)
      try {
        const result = (await request("inspectTranscriptSource", { source })) as TranscriptEvidence
        if (active && token === evidenceRequest.current && result.meetingID === source.meetingID) {
          setEvidence(result)
          setError(null)
        }
      } catch (reason) {
        if (active && token === evidenceRequest.current)
          setError(reason instanceof Error ? reason.message : String(reason))
      }
    }
    const listener = (event: Event) => {
      void inspect(event)
    }
    window.addEventListener("aside-inspect-source", listener)
    return () => {
      active = false
      window.removeEventListener("aside-inspect-source", listener)
    }
  }, [state.meeting?.id])
  const meeting = state.meeting
  useEffect(() => {
    const openContext = () => setModal(state.meeting ? "details" : "new")
    window.addEventListener("aside-open-context", openContext)
    return () => window.removeEventListener("aside-open-context", openContext)
  }, [state.meeting])
  const provisional =
    !!meeting?.recognitionDraft &&
    meeting.document?.author !== "user" &&
    !meeting.segments.some(
      (segment) =>
        segment.kind !== "note" &&
        !(
          segment.kind == null &&
          segment.start === segment.end &&
          /^[a-f0-9-]{36}$/i.test(segment.id)
        )
    )
  const visibleMeeting =
    meeting && provisional && meeting.recognitionDraft
      ? {
          ...meeting,
          document: undefined,
          segments: [...meeting.recognitionDraft.segments, ...meeting.segments].sort(
            (a, b) => a.start - b.start
          ),
        }
      : meeting
  const audioSources = state.audioExports ?? []
  const exportSource =
    audioSources.find((source) => source.label === audioSource) ?? audioSources[0]
  const audioExportDisabled =
    !state.runtime.native ||
    !exportSource ||
    busy.has("exportAudio") ||
    meeting?.status === "recording" ||
    meeting?.status === "processing"
  async function createMeeting() {
    const okay = await act("createMeeting")
    if (okay) {
      setView("meeting")
      setSearch("")
      setRaw(false)
      setRenamingMeeting(null)
    }
    return okay
  }
  function editMeetingName(id: string, title: string) {
    setRenamingMeeting(id)
    setMeetingTitleDraft(title)
  }
  async function saveMeetingName() {
    if (
      renamingMeeting &&
      (await act("renameMeeting", { id: renamingMeeting, title: meetingTitleDraft }))
    )
      setRenamingMeeting(null)
  }
  useKeys([
    {
      key: "n",
      mod: true,
      run: () => {
        if (!state.runtime.recording) void createMeeting()
      },
    },
    {
      key: "e",
      mod: true,
      run: () => {
        if (meeting) setModal("export")
      },
    },
    { key: ",", mod: true, run: () => setModal("settings") },
  ])
  async function toggleRecord() {
    if (state.runtime.recording) await act("stopRecording")
    else if (!state.runtime.native || state.runtime.modelStatus !== "ready") setModal("settings")
    else if (!meeting) {
      if (await createMeeting()) await act("startRecording")
    } else await act("startRecording")
  }
  const transcriptProgress = busy.has("stopRecording")
    ? "Saving recording…"
    : meeting?.status === "processing"
      ? meeting.pendingStage === "polish"
        ? "Writing final transcript…"
        : "Preparing final transcript…"
      : null
  const alert = error ?? state.runtime.lastError
  const docs = state.documents.filter((doc) =>
    doc.name.toLowerCase().includes(librarySearch.toLowerCase())
  )
  const terms = state.glossary.filter((entry) =>
    `${entry.term} ${entry.aliases.join(" ")} ${entry.definition}`
      .toLowerCase()
      .includes(librarySearch.toLowerCase())
  )
  const transcriptNavigation = (
    <div className="transcript-navigation">
      {meeting && meeting.segments.length > 0 && (
        <>
          <div className="transcript-view-toggle">
            <button
              type="button"
              onClick={() => setRaw(false)}
              aria-pressed={!raw}
              className={cn(
                "text-xs",
                !raw ? "font-semibold text-primary-ink" : "text-muted-foreground"
              )}
            >
              Repaired
            </button>
            <span className="text-xs text-border-strong">/</span>
            <button
              type="button"
              onClick={() => setRaw(true)}
              aria-pressed={raw}
              className={cn(
                "text-xs",
                raw ? "font-semibold text-primary-ink" : "text-muted-foreground"
              )}
            >
              Original
            </button>
          </div>
          <label className="transcript-search">
            <Search className="size-3.5 text-muted-foreground" />
            <input
              aria-label="Search transcript"
              placeholder="Find"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              className="bg-transparent text-xs outline-none"
            />
          </label>
        </>
      )}
      <details
        className="meeting-actions"
        onBlur={(event) => {
          if (!event.currentTarget.contains(event.relatedTarget as Node | null))
            event.currentTarget.open = false
        }}
      >
        <summary aria-label="Meeting actions" title="Meeting actions">
          <Ellipsis className="size-4" />
        </summary>
        <div className="meeting-actions-panel">
          {meeting && meeting.audioTracks.length > 0 && !state.runtime.recording && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Improve recognition from saved audio"
              title="Improve recognition from saved audio"
              disabled={busy.has("reprocessAudio") || meeting.status === "processing"}
              onClick={() => void act("reprocessAudio")}
            >
              <History />
              <span>Improve recognition from saved audio</span>
            </Button>
          )}
          {meeting && meeting.audioTracks.length > 0 && !provisional && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Identify voices from saved audio"
              title={
                state.runtime.speakerModelStatus === "ready"
                  ? "Identify voices without changing the recognized words"
                  : "Set up speaker identification in Settings first"
              }
              disabled={
                !state.runtime.native ||
                state.runtime.recording ||
                busy.has("identifySavedSpeakers") ||
                meeting.status === "processing" ||
                state.runtime.speakerModelStatus !== "ready"
              }
              onClick={() => void act("identifySavedSpeakers")}
            >
              {busy.has("identifySavedSpeakers") ? (
                <LoaderCircle className="animate-spin" />
              ) : (
                <UsersRound />
              )}
              <span>Identify voices from saved audio</span>
            </Button>
          )}
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Import an audio recording"
            disabled={!meeting || busy.has("importAudio") || state.runtime.recording}
            onClick={() => void act("importAudio")}
          >
            <Upload />
            <span>Import an audio recording</span>
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Add a passage"
            disabled={!meeting}
            onClick={() => setModal("passage")}
          >
            <Plus />
            <span>Add a passage</span>
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Export meeting"
            disabled={!meeting}
            onClick={() => setModal("export")}
          >
            <ArrowDownToLine />
            <span>Export meeting</span>
          </Button>
          {meeting && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Delete meeting"
              className="text-destructive"
              disabled={
                !state.runtime.native ||
                state.runtime.recording ||
                meeting.status === "processing" ||
                state.runtime.answering ||
                busy.has("exportNarration")
              }
              title={
                !state.runtime.native
                  ? "Delete meetings in the Mac app"
                  : "Move this meeting, transcript and recordings to Trash"
              }
              onClick={() => setModal("delete")}
            >
              <Trash2 />
              <span>Delete meeting…</span>
            </Button>
          )}
          {meeting && new Set(meeting.segments.map((segment) => segment.speaker)).size > 0 && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label="Speaker names"
              title="Speaker names"
              onClick={() => setModal("speakers")}
            >
              <UsersRound />
              <span>Speaker names</span>
            </Button>
          )}
        </div>
      </details>
    </div>
  )
  return (
    <div className="aside-app">
      {evidence && evidence.meetingID === state.meeting?.id && (
        <Modal
          title={evidence.title}
          description={`${evidence.revision} · ${evidence.location}`}
          close={closeEvidence}
        >
          {!evidence.current && (
            <p className="mb-4 text-sm text-muted-foreground">
              This passage comes from a retained earlier version of the transcript.
            </p>
          )}
          {evidence.excerpt && (
            <blockquote className="border-l-2 pl-4 text-sm leading-relaxed">
              {evidence.excerpt}
            </blockquote>
          )}
          {evidence.text !== evidence.excerpt && (
            <p
              className={cn(
                "whitespace-pre-wrap text-sm leading-relaxed",
                evidence.excerpt && "mt-4"
              )}
            >
              {evidence.text}
            </p>
          )}
          {evidence.rawText && evidence.rawText !== evidence.text && (
            <details className="mt-4 text-sm text-muted-foreground">
              <summary className="cursor-pointer">Original recognition</summary>
              <p className="mt-2 whitespace-pre-wrap leading-relaxed">{evidence.rawText}</p>
            </details>
          )}
          {error && (
            <div className="mt-4 rounded-lg border bg-sunken p-3" role="alert">
              <p className="text-sm font-medium">Action could not finish</p>
              <p className="mt-1 text-xs leading-relaxed text-muted-foreground">{error}</p>
            </div>
          )}
        </Modal>
      )}
      <AppBar
        product="Aside"
        icon={<AppIcon />}
        className="aside-appbar"
        center={
          <span className="text-xs tracking-wide text-muted-foreground">
            Your meeting companion
          </span>
        }
        right={
          <>
            <ShortcutsHelp
              items={[
                ["⌘ N", "new meeting"],
                ["⌘ E", "export meeting"],
                ["⌘ ,", "settings"],
              ]}
            />
            {state.runtime.contextFloating && (
              <Button
                variant="ghost"
                size="icon"
                aria-label="Show floating help"
                title="Show floating contextual help"
                onClick={() => void act("floatContext")}
              >
                <PictureInPicture2 />
              </Button>
            )}
            <Button
              variant="ghost"
              size="icon"
              onClick={() => setModal("settings")}
              aria-label="Settings"
            >
              <Settings2 />
            </Button>
            <div className="ml-1 hidden items-center gap-2 border-l pl-4 text-xs text-muted-foreground sm:flex">
              <ShieldCheck className="size-3.5" />
              Local workspace
            </div>
          </>
        }
      />
      {!state.runtime.native && (
        <div className="preview-banner">
          <span>Browser workspace preview</span>
          <span className="text-muted-foreground">
            Recording and AI run in the Aside Mac app. Notes and glossary save in this browser.
          </span>
        </div>
      )}
      {alert && (
        <div role="alert" className="error-banner">
          <CircleHelp className="size-4 shrink-0" />
          <span className="min-w-0 flex-1 break-words">{alert}</span>
          <Button
            size="icon-xs"
            variant="ghost"
            aria-label="Dismiss error"
            onClick={() => {
              setError(null)
              void request("clearError")
            }}
          >
            <X />
          </Button>
        </div>
      )}
      <div
        className={cn(
          "aside-layout",
          state.runtime.contextFloating && view === "meeting" && "context-detached"
        )}
      >
        <aside className="meeting-sidebar" aria-label="Workspace navigation">
          <div className="px-4 pb-5 pt-6">
            <Button
              className="h-10 w-full justify-start gap-2.5"
              onClick={() => void createMeeting()}
              disabled={state.runtime.recording || busy.has("createMeeting")}
            >
              <Plus />
              New meeting
              <span className="ml-auto text-[11px] opacity-65 pointer-coarse:hidden">⌘ N</span>
            </Button>
          </div>
          <nav className="grid gap-1 px-3">
            <button
              type="button"
              className={cn("nav-item", view === "meeting" && "selected")}
              onClick={() => setView("meeting")}
            >
              <AudioLines />
              Meetings
              <span className="ml-auto text-xs text-muted-foreground">{state.meetings.length}</span>
            </button>
            <button
              type="button"
              className={cn("nav-item", view === "documents" && "selected")}
              onClick={() => {
                setView("documents")
                setLibrarySearch("")
              }}
            >
              <BookOpen />
              Context library
              <span className="ml-auto text-xs text-muted-foreground">
                {state.documents.length}
              </span>
            </button>
            <button
              type="button"
              className={cn("nav-item", view === "glossary" && "selected")}
              onClick={() => {
                setView("glossary")
                setLibrarySearch("")
              }}
            >
              <Languages />
              Your vocabulary
              <span className="ml-auto text-xs text-muted-foreground">{state.glossary.length}</span>
            </button>
          </nav>
          <div className="mt-8 flex items-center justify-between px-5">
            <Eyebrow>Your meetings</Eyebrow>
            <Clock3 className="size-3 text-muted-foreground" />
          </div>
          <div className="meeting-list">
            {state.meetings.length ? (
              state.meetings.map((item) => (
                <ContextActions
                  key={item.id}
                  disabled={renamingMeeting === item.id}
                  actions={[
                    {
                      label: "Open meeting",
                      disabled: state.runtime.recording && item.id !== meeting?.id,
                      run: () => {
                        void act("selectMeeting", { id: item.id })
                        setView("meeting")
                        setSearch("")
                      },
                    },
                    {
                      label: "Rename meeting…",
                      disabled: state.runtime.recording,
                      run: () => editMeetingName(item.id, item.title),
                    },
                    {
                      label: "Export meeting…",
                      disabled: state.runtime.recording,
                      run: () => {
                        void (async () => {
                          if (await act("selectMeeting", { id: item.id })) {
                            setView("meeting")
                            setModal("export")
                          }
                        })()
                      },
                    },
                    {
                      label: "Delete meeting…",
                      separator: true,
                      destructive: true,
                      disabled:
                        !state.runtime.native ||
                        state.runtime.recording ||
                        item.status === "processing" ||
                        state.runtime.answering ||
                        busy.has("exportNarration"),
                      run: () => {
                        void (async () => {
                          if (await act("selectMeeting", { id: item.id })) {
                            setView("meeting")
                            setModal("delete")
                          }
                        })()
                      },
                    },
                  ]}
                >
                  {renamingMeeting === item.id ? (
                    <div className="meeting-item selected gap-1">
                      <Input
                        autoFocus
                        aria-label="Meeting name"
                        value={meetingTitleDraft}
                        className="h-8 min-w-0 flex-1 text-sm"
                        disabled={busy.has("renameMeeting")}
                        onFocus={(event) => event.currentTarget.select()}
                        onChange={(event) => setMeetingTitleDraft(event.target.value)}
                        onKeyDown={(event) => {
                          if (event.key === "Enter") {
                            event.preventDefault()
                            void saveMeetingName()
                          } else if (event.key === "Escape") setRenamingMeeting(null)
                        }}
                      />
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label="Save meeting name"
                        disabled={!meetingTitleDraft.trim() || busy.has("renameMeeting")}
                        onClick={() => void saveMeetingName()}
                      >
                        <Check />
                      </Button>
                      <Button
                        variant="ghost"
                        size="icon-xs"
                        aria-label="Cancel meeting rename"
                        onClick={() => setRenamingMeeting(null)}
                      >
                        <X />
                      </Button>
                    </div>
                  ) : (
                    <button
                      type="button"
                      onDoubleClick={() => editMeetingName(item.id, item.title)}
                      className={cn(
                        "meeting-item",
                        meeting?.id === item.id && view === "meeting" && "selected"
                      )}
                      disabled={state.runtime.recording && item.id !== meeting?.id}
                      onClick={() => {
                        void act("selectMeeting", { id: item.id })
                        setView("meeting")
                        setSearch("")
                      }}
                    >
                      <span className="meeting-glyph">
                        <AudioLines className="size-4" />
                      </span>
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-medium">{item.title}</span>
                        <span className="mt-1 flex flex-wrap gap-x-2 text-[11px] text-muted-foreground">
                          <span>{dateLabel(item.createdAt)}</span>
                          <span>
                            {item.status === "recording"
                              ? "Recording"
                              : item.status === "processing"
                                ? "Finalizing transcript…"
                                : item.segmentCount
                                  ? `${item.segmentCount} passages`
                                  : "Ready to begin"}
                          </span>
                        </span>
                      </span>
                      {item.status === "recording" && <span className="live-dot !size-1.5" />}
                      {item.status === "processing" && (
                        <LoaderCircle
                          className="size-3.5 shrink-0 animate-spin text-primary-ink"
                          aria-hidden="true"
                        />
                      )}
                    </button>
                  )}
                </ContextActions>
              ))
            ) : (
              <p className="px-5 py-4 text-xs leading-relaxed text-muted-foreground">
                Your conversations will be kept here, ready to return to.
              </p>
            )}
          </div>
          <div className="sidebar-footer">
            <div className="flex items-center gap-2 text-xs font-medium">
              <span
                className={cn(
                  "size-1.5 rounded-full",
                  state.runtime.modelStatus === "ready" ? "bg-good" : "bg-border-strong"
                )}
              />
              {state.runtime.modelStatus === "ready" ? "Local speech ready" : "Local speech setup"}
            </div>
            <p className="mt-1.5 text-[11px] leading-relaxed text-muted-foreground">
              Parakeet · English and Spanish
            </p>
            <Button
              variant="link"
              size="xs"
              className="mt-2 h-auto px-0"
              onClick={() => setModal("settings")}
            >
              {state.runtime.modelStatus === "ready" ? "Preferences" : "Set up your Mac"}
              <ArrowRight />
            </Button>
          </div>
        </aside>
        {view === "meeting" ? (
          <>
            <main className="meeting-main">
              <div className="meeting-heading">
                <div className="min-w-0 flex-1">
                  <button
                    type="button"
                    className="meeting-title-button"
                    title={
                      meeting
                        ? `${dateLabel(meeting.createdAt)} · ${languageNames[meeting.language]}`
                        : undefined
                    }
                    onClick={() => {
                      if (meeting) setModal("details")
                      else void createMeeting()
                    }}
                  >
                    <h1 className="truncate text-lg">
                      {meeting?.title ?? "Your meeting workspace"}
                    </h1>
                    {meeting && <PenLine className="size-3.5 shrink-0 text-muted-foreground" />}
                  </button>
                </div>
                {transcriptProgress && (
                  <div
                    role="status"
                    aria-label="Transcript progress"
                    aria-live="polite"
                    className="flex min-w-0 shrink items-center gap-2 rounded-md bg-primary-soft px-2.5 py-1.5 text-xs font-medium text-primary-ink"
                    title={
                      busy.has("stopRecording")
                        ? "Saving your recording before final transcription."
                        : "Your recording is saved; the text below will update when the final transcript is ready."
                    }
                  >
                    <LoaderCircle className="size-3.5 shrink-0 animate-spin" aria-hidden="true" />
                    <span className="truncate">{transcriptProgress}</span>
                  </div>
                )}
                {meeting && (
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    aria-label="Edit meeting context"
                    title={`Meeting context · ${meeting.documentIDs.length} documents`}
                    onClick={() => setModal("details")}
                  >
                    <BookOpen />
                  </Button>
                )}
                <Button
                  variant={state.runtime.recording ? "destructive" : "default"}
                  className="h-8"
                  onClick={() => void toggleRecord()}
                  disabled={busy.has("startRecording") || busy.has("stopRecording")}
                >
                  {busy.has("startRecording") || busy.has("stopRecording") ? (
                    <LoaderCircle className="animate-spin" />
                  ) : state.runtime.recording ? (
                    <Square className="size-3 fill-current" />
                  ) : (
                    <Mic />
                  )}
                  <span>
                    {busy.has("stopRecording")
                      ? "Finishing…"
                      : state.runtime.recording
                        ? "Stop"
                        : "Record"}
                  </span>
                </Button>
              </div>
              {meeting?.pendingStage && meeting.status === "interrupted" && (
                <div className="flex items-center justify-between gap-3 border-b px-6 py-3 text-sm">
                  <span className="text-muted-foreground">
                    {meeting.processingError ??
                      "Processing was interrupted. Saved audio and transcript are intact."}
                  </span>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy.has("resumeProcessing")}
                    onClick={() => void act("resumeProcessing")}
                  >
                    {busy.has("resumeProcessing") ? (
                      <LoaderCircle className="animate-spin" />
                    ) : (
                      <ArrowRight />
                    )}{" "}
                    Resume processing
                  </Button>
                </div>
              )}
              {visibleMeeting && visibleMeeting.segments.length > 0 ? (
                <Transcript
                  key={visibleMeeting.id}
                  meeting={visibleMeeting}
                  provisional={provisional}
                  act={act}
                  raw={raw}
                  search={search}
                  busy={busy}
                  toolbar={transcriptNavigation}
                />
              ) : (
                <>
                  <div className="document-tools">{transcriptNavigation}</div>
                  <EmptyTranscript
                    state={state}
                    act={act}
                    busy={busy}
                    open={(name) => {
                      if (name === "new") void createMeeting()
                      else setModal(name)
                    }}
                  />
                </>
              )}
              <footer className={cn("recording-footer", state.runtime.recording && "is-recording")}>
                <div className="flex items-center gap-3">
                  <span className="num font-mono text-xs text-ink-2">
                    {formatDuration(meeting?.duration ?? 0)}
                  </span>
                  <span className="text-xs text-muted-foreground">
                    {state.runtime.recording
                      ? state.runtime.captureHealth?.systemAudio === "failed"
                        ? "Microphone recording · System audio stopped"
                        : Object.values(state.runtime.captureHealth ?? {}).includes("warning")
                          ? "Recording · Check capture issues"
                          : "Recording locally"
                      : meeting?.audioTracks.length
                        ? "Recording saved"
                        : "Ready when you are"}
                  </span>
                </div>
                {state.runtime.recording ? (
                  <AudioLevel value={state.runtime.inputLevel} label="Mic" />
                ) : (
                  <span className="flex items-center gap-1.5 text-[11px] text-muted-foreground">
                    <ShieldCheck className="size-3" />
                    Saved on this device
                  </span>
                )}
              </footer>
            </main>
            {!state.runtime.contextFloating && (
              <AssistantPane
                state={state}
                act={act}
                busy={busy}
                onContext={() => setModal(meeting ? "details" : "new")}
              />
            )}
          </>
        ) : (
          <main className="library-main">
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div>
                <Eyebrow>
                  {view === "documents"
                    ? "Your knowledge, within reach"
                    : "The words that matter to you"}
                </Eyebrow>
                <h1 className="mt-3 text-[28px]">
                  {view === "documents" ? "Context library" : "Your vocabulary"}
                </h1>
                <p className="mt-3 text-sm leading-relaxed text-muted-foreground measure">
                  {view === "documents"
                    ? "Bring the documents behind the conversation. Choose which ones the assistant can use in each meeting."
                    : "Names, technical terms, and the ways they sometimes get misheard. A glossary that grows around your work."}
                </p>
              </div>
              <Button
                onClick={() =>
                  view === "documents" ? void act("addDocuments") : setModal("glossary")
                }
                disabled={busy.has("addDocuments")}
              >
                <Plus />
                {view === "documents" ? "Add documents" : "Add a term"}
              </Button>
            </div>
            <div className="mt-8 flex flex-wrap items-center justify-between gap-3 border-b pb-4">
              <div className="flex items-center gap-2">
                <Search className="size-4 text-muted-foreground" />
                <input
                  className="bg-transparent text-sm outline-none"
                  aria-label={`Search ${view === "documents" ? "documents" : "vocabulary"}`}
                  placeholder={view === "documents" ? "Find a document…" : "Find a term…"}
                  value={librarySearch}
                  onChange={(event) => setLibrarySearch(event.target.value)}
                />
              </div>
              <div className="flex items-center gap-3">
                <span className="text-xs text-muted-foreground">
                  {view === "documents" ? docs.length : terms.length}/
                  {view === "documents" ? state.documents.length : state.glossary.length} shown
                </span>
                {view === "glossary" && (
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={!meeting?.documentIDs.length || busy.has("extractGlossary")}
                    title={
                      !meeting?.documentIDs.length
                        ? "Attach documents to a meeting first"
                        : "Suggest terms from meeting documents"
                    }
                    onClick={() => void act("extractGlossary")}
                  >
                    {busy.has("extractGlossary") ? (
                      <LoaderCircle className="animate-spin" />
                    ) : (
                      <Sparkles />
                    )}
                    Find terms in documents
                  </Button>
                )}
              </div>
            </div>
            {view === "documents" ? (
              docs.length ? (
                <div className="document-grid">
                  {docs.map((doc) => (
                    <article className="document-card" key={doc.id}>
                      <div className="flex items-start justify-between">
                        <div className="rounded-xl bg-primary-soft p-3 text-primary">
                          <FileText className="size-5" />
                        </div>
                        <span className="rounded bg-muted px-2 py-1 font-mono text-[10px] uppercase text-muted-foreground">
                          {doc.kind}
                        </span>
                      </div>
                      <h3 className="mt-5 break-words text-sm font-semibold">{doc.name}</h3>
                      <p className="mt-2 text-xs text-muted-foreground">
                        {doc.characters.toLocaleString()} characters · Added{" "}
                        {dateLabel(doc.addedAt)}
                      </p>
                      <div className="mt-5 flex items-center justify-between">
                        <span className="text-[11px] text-muted-foreground">
                          {meeting?.documentIDs.includes(doc.id)
                            ? "In this meeting"
                            : "In your library"}
                        </span>
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() => void act("openSource", { documentID: doc.id })}
                        >
                          Open
                          <ArrowRight />
                        </Button>
                      </div>
                    </article>
                  ))}
                </div>
              ) : (
                <LibraryEmpty
                  icon={<BookOpen />}
                  title={librarySearch ? "No matching documents" : "Bring a little background."}
                  text={
                    librarySearch
                      ? "Try a different name or clear the search."
                      : "Add briefs, reports, notes, or project documents. In the Mac app, PDF, Word, Markdown, and plain text are supported."
                  }
                />
              )
            ) : terms.length ? (
              <div className="mt-2">
                {terms.map((entry) => (
                  <article key={entry.id} className="glossary-row">
                    <div className="min-w-0">
                      <h3 className="text-sm font-semibold">{entry.term}</h3>
                      {entry.aliases.length > 0 && (
                        <div className="mt-2 flex flex-wrap gap-1.5">
                          {entry.aliases.map((alias) => (
                            <span
                              key={alias}
                              className="rounded border px-2 py-0.5 font-mono text-[11px] text-muted-foreground"
                            >
                              {alias}
                            </span>
                          ))}
                        </div>
                      )}
                      <p className="mt-2 text-sm leading-relaxed text-ink-2">
                        {entry.definition || "No definition added."}
                      </p>
                      <p className="mt-2 text-[11px] text-muted-foreground">{entry.source}</p>
                    </div>
                    <Button
                      size="icon-sm"
                      variant="ghost"
                      aria-label={`Remove ${entry.term}`}
                      onClick={async () => {
                        if (await act("removeGlossary", { id: entry.id })) setUndo(entry)
                      }}
                    >
                      <Trash2 />
                    </Button>
                  </article>
                ))}
              </div>
            ) : (
              <LibraryEmpty
                icon={<Languages />}
                title={librarySearch ? "No matching terms" : "A vocabulary of your own."}
                text={
                  librarySearch
                    ? "Try another spelling or clear the search."
                    : "Start with a name or technical term that often gets misheard. You can also find terms in the documents attached to a meeting."
                }
              />
            )}
            {undo && view === "glossary" && (
              <div className="mt-4 flex items-center justify-between gap-3 rounded-lg border bg-card p-3 text-sm">
                <span>Removed {undo.term}.</span>
                <Button
                  variant="link"
                  size="sm"
                  onClick={async () => {
                    if (
                      await act("addGlossary", {
                        term: undo.term,
                        aliases: undo.aliases,
                        definition: undo.definition,
                      })
                    )
                      setUndo(null)
                  }}
                >
                  Undo
                </Button>
              </div>
            )}
          </main>
        )}
      </div>
      {modal && (
        <Modal
          title={
            modal === "new"
              ? "Make room for a meeting"
              : modal === "delete"
                ? "Delete this meeting?"
                : modal === "speakers"
                  ? "Speaker names"
                  : modal === "details"
                    ? "Meeting context"
                    : modal === "settings"
                      ? "Make Aside yours"
                      : modal === "passage"
                        ? editing
                          ? "Edit this passage"
                          : "Add to the conversation"
                        : modal === "glossary"
                          ? "A word worth knowing"
                          : "Take the conversation with you"
          }
          description={
            modal === "new"
              ? "A little preparation helps the assistant follow your lead."
              : modal === "export"
                ? "Download the written transcript, recordings, or complete meeting record."
                : undefined
          }
          close={close}
        >
          {modal === "new" && (
            <MeetingForm
              state={state}
              act={async (action, payload) => {
                const okay = await act(action, payload)
                if (okay) setView("meeting")
                return okay
              }}
              close={close}
            />
          )}
          {modal === "details" && meeting && (
            <>
              <MeetingForm meeting={meeting} state={state} act={act} close={close} />
              <div className="mt-5 border-t pt-4">
                <Button variant="outline" size="sm" onClick={() => void act("addDocuments")}>
                  <Plus />
                  Add documents to this meeting
                </Button>
              </div>
            </>
          )}
          {modal === "delete" && meeting && (
            <div>
              <p className="text-sm leading-relaxed">
                Move <strong>{meeting.title}</strong>, its transcript and all its recordings to
                macOS Trash?
              </p>
              <p className="mt-3 text-sm text-muted-foreground">
                You can recover it from Trash. Saved voice profiles and shared context stay in
                Aside.
              </p>
              <div className="mt-6 flex justify-end gap-2">
                <Button variant="ghost" onClick={close}>
                  Cancel
                </Button>
                <Button
                  variant="destructive"
                  disabled={busy.has("deleteMeeting")}
                  onClick={async () => {
                    if (await act("deleteMeeting", { id: meeting.id })) {
                      setSearch("")
                      setView("meeting")
                      close()
                    }
                  }}
                >
                  {busy.has("deleteMeeting") ? (
                    <LoaderCircle className="animate-spin" />
                  ) : (
                    <Trash2 />
                  )}
                  Move to Trash
                </Button>
              </div>
            </div>
          )}
          {modal === "speakers" && meeting && (
            <SpeakerNamesForm
              meeting={meeting}
              voiceProfiles={state.voiceProfiles}
              native={state.runtime.native}
              recording={state.runtime.recording}
              act={act}
              close={close}
            />
          )}
          {modal === "settings" && <SettingsPanel state={state} act={act} busy={busy} />}
          {modal === "passage" && <PassageForm segment={editing} act={act} close={close} />}
          {modal === "glossary" && <GlossaryForm act={act} close={close} />}
          {modal === "export" && (
            <div className="grid gap-3">
              <Button
                variant="outline"
                className="h-auto justify-between p-4"
                onClick={() => void act("exportMeeting", { format: "markdown" })}
              >
                <span className="flex items-center gap-3">
                  <FileText />
                  <span>Written document · Markdown</span>
                </span>
                <ArrowDownToLine />
              </Button>
              <Button
                variant="outline"
                className="h-auto justify-between p-4"
                onClick={() => void act("exportMeeting", { format: "json" })}
              >
                <span className="flex items-center gap-3">
                  <FileAudio />
                  <span>Complete JSON record</span>
                </span>
                <ArrowDownToLine />
              </Button>
              <div className="mt-1 grid gap-3 border-t pt-4">
                {audioSources.length > 1 && (
                  <label className="grid gap-2 text-sm">
                    Recording source
                    <select
                      className="aside-select"
                      value={exportSource?.label ?? ""}
                      onChange={(event) => setAudioSource(event.target.value)}
                    >
                      {audioSources.map((source) => (
                        <option key={source.label} value={source.label}>
                          {source.label}
                        </option>
                      ))}
                    </select>
                  </label>
                )}
                <Button
                  variant="outline"
                  className="h-auto justify-between p-4"
                  disabled={audioExportDisabled}
                  onClick={() =>
                    void act("exportAudio", { source: exportSource?.label, prepared: false })
                  }
                >
                  <span className="flex items-center gap-3">
                    <AudioLines />
                    <span>Original recording · WAV</span>
                  </span>
                  <ArrowDownToLine />
                </Button>
                <Button
                  variant="outline"
                  className="h-auto justify-between p-4"
                  disabled={audioExportDisabled || !exportSource?.preparedAvailable}
                  onClick={() =>
                    void act("exportAudio", { source: exportSource?.label, prepared: true })
                  }
                >
                  <span className="flex items-center gap-3">
                    <Sparkles />
                    <span>Prepared recording · WAV</span>
                  </span>
                  <ArrowDownToLine />
                </Button>
                <p className="text-xs leading-relaxed text-muted-foreground">
                  Prepared audio is the input from the latest recognition pass, including any pause
                  shortening or filler masking you enabled. Transcript wording repairs change only
                  the text.
                  {!exportSource?.preparedAvailable &&
                    " Use Improve recognition from saved audio to prepare it."}
                </p>
              </div>
              <NarrationExport state={state} act={act} busy={busy} />
            </div>
          )}
        </Modal>
      )}
    </div>
  )
}

export function LibraryEmpty({
  icon,
  title,
  text,
}: {
  icon: ReactNode
  title: string
  text: string
}) {
  return (
    <div className="mx-auto flex max-w-sm flex-col items-center py-20 text-center">
      <span className="rounded-2xl bg-primary-soft p-4 text-primary">{icon}</span>
      <h2 className="mt-5 text-lg">{title}</h2>
      <p className="mt-3 text-sm leading-relaxed text-muted-foreground">{text}</p>
    </div>
  )
}
