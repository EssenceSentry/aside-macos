import {
  ArrowDownToLine,
  AudioLines,
  Check,
  Clipboard,
  Info,
  Languages,
  LoaderCircle,
  Mic,
  PenLine,
  Search,
  ShieldCheck,
  Sparkles,
  X,
} from "lucide-react"
import { type ReactNode, useEffect, useMemo, useRef, useState } from "react"
import { ContextActions } from "@/blocks/context-actions"
import { Eyebrow } from "@/blocks/primitives"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import {
  documentParagraphs,
  documentSpeakers,
  documentText,
  transcriptFingerprint,
} from "@/lib/document"
import type { AppState, Meeting } from "@/lib/types"
import { cn } from "@/lib/utils"
import type { Act, ModalName } from "@/screens/shared"

export function Transcript({
  meeting,
  act,
  raw,
  search,
  busy,
  provisional = false,
  toolbar,
}: {
  meeting: Meeting
  provisional?: boolean
  toolbar?: ReactNode
  act: Act
  raw: boolean
  search: string
  busy: Set<string>
}) {
  const scroll = useRef<HTMLDivElement>(null)
  const [follow, setFollow] = useState(true)
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState("")
  const [editingFingerprint, setEditingFingerprint] = useState("")
  const [editingRevision, setEditingRevision] = useState(0)
  const [copied, setCopied] = useState(false)
  const [onlyMe, setOnlyMe] = useState(false)
  const [renaming, setRenaming] = useState<{
    meetingID: string
    speaker: string
    paragraphID: string
  } | null>(null)
  const [speakerDraft, setSpeakerDraft] = useState("")
  const [contextSelection, setContextSelection] = useState("")
  function speakerName(speaker: string) {
    return (
      meeting.speakerNames?.[speaker] ??
      speaker.replace(/^(?:Imported audio|Microphone|System audio) · /, "")
    )
  }
  async function saveSpeaker() {
    if (
      renaming?.meetingID === meeting.id &&
      (await act("renameSpeaker", {
        meetingID: renaming.meetingID,
        speaker: renaming.speaker,
        name: speakerDraft,
      }))
    )
      setRenaming(null)
  }
  const { document: readableDocument, segments, speakerNames } = meeting
  const paragraphs = useMemo(
    () => documentParagraphs({ document: readableDocument, segments, speakerNames }, raw),
    [readableDocument, segments, speakerNames, raw]
  )
  const text = useMemo(
    () => documentText({ document: readableDocument, segments, speakerNames }, raw, paragraphs),
    [readableDocument, speakerNames, segments, paragraphs, raw]
  )
  const speakers = useMemo(
    () => documentSpeakers({ document: readableDocument, segments }),
    [readableDocument, segments]
  )
  const multipleSpeakers = speakers.size > 1
  const hasMe = speakers.has("You")
  const alignedBlocks =
    !!readableDocument?.blocks?.length &&
    (readableDocument.author !== "user" ||
      readableDocument.blocks.map((block) => block.text).join("\n\n") === readableDocument.text)
  const canFilterMe = hasMe && (raw || !readableDocument || alignedBlocks)
  const filterMe = onlyMe && canFilterMe
  useEffect(() => {
    const clear = () => setOnlyMe(false)
    window.addEventListener("aside-clear-speaker-filter", clear)
    return () => window.removeEventListener("aside-clear-speaker-filter", clear)
  }, [])
  const shown = paragraphs.filter(
    (paragraph) =>
      (!filterMe || paragraph.speaker === "You") &&
      paragraph.text.toLowerCase().includes(search.toLowerCase())
  )
  // Keep one canonical DOM anchor, even when several displayed runs share its ID.
  const firstRunBySource = new Map<string, string>()
  for (const segment of shown.flatMap((paragraph) => paragraph.segments)) {
    if (!firstRunBySource.has(segment.id)) firstRunBySource.set(segment.id, segment.presentationID)
  }
  const count = meeting.segments.length
  useEffect(() => {
    if (count > 0 && follow && !search && meeting.status === "recording")
      scroll.current?.scrollTo({ top: scroll.current.scrollHeight, behavior: "smooth" })
  }, [count, follow, search, meeting.status])
  async function copy() {
    const copiedText = filterMe ? shown.map((paragraph) => paragraph.text).join("\n\n") : text
    if (await act("copyText", { text: copiedText })) {
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    }
  }
  function edit() {
    setDraft(text)
    setEditingFingerprint(transcriptFingerprint(meeting.segments))
    setEditingRevision(meeting.document?.revision ?? 0)
    setEditing(true)
  }
  function rename(speaker: string, paragraphID: string) {
    setRenaming({ meetingID: meeting.id, speaker, paragraphID })
    setSpeakerDraft(speakerName(speaker))
  }
  async function save() {
    if (
      await act("editDocument", {
        text: draft,
        revision: editingRevision,
        baseFingerprint: editingFingerprint,
      })
    )
      setEditing(false)
  }
  return (
    <div className="transcript-document-shell">
      <div className="document-tools">
        {toolbar}
        <div className="flex items-center gap-2">
          <details
            className="transcript-details"
            onBlur={(event) => {
              if (!event.currentTarget.contains(event.relatedTarget as Node | null))
                event.currentTarget.open = false
            }}
          >
            <summary aria-label="Recording details" title="Recording details">
              <Info className="size-4" />
            </summary>
            <div className="transcript-details-panel">
              <p className="px-4 py-3 text-xs text-muted-foreground">
                {
                  paragraphs
                    .map((paragraph) => paragraph.text)
                    .join(" ")
                    .trim()
                    .split(/\s+/)
                    .filter(Boolean).length
                }{" "}
                words · {Math.floor(meeting.duration / 60)} min
              </p>
              {meeting.startIncomplete && (
                <p className="border-b px-6 py-2 text-xs text-muted-foreground">
                  Opening missing · This recording starts after the meeting began.
                </p>
              )}
              {meeting.speakerNotice && (
                <p className="border-b px-6 py-2 text-xs leading-relaxed text-muted-foreground">
                  {meeting.speakerNotice}
                </p>
              )}
              {meeting.recognitionNotice && (
                <p className="border-b px-6 py-2 text-xs leading-relaxed text-muted-foreground">
                  {meeting.recognitionNotice}
                </p>
              )}
              {!!meeting.captureIssues?.length && (
                <details className="border-b px-6 py-2 text-xs text-muted-foreground">
                  <summary className="cursor-pointer">
                    Recording has {meeting.captureIssues.length} capture{" "}
                    {meeting.captureIssues.length === 1 ? "issue" : "issues"}
                  </summary>
                  {meeting.captureIssues.map((issue) => (
                    <p
                      key={`${issue.source}-${issue.kind}-${issue.offset}-${issue.duration}-${issue.message}`}
                      className="mt-2 leading-relaxed"
                    >
                      {issue.message}
                    </p>
                  ))}
                  <p className="mt-2 leading-relaxed">
                    Missing audio cannot be recovered from context.
                  </p>
                </details>
              )}
            </div>
          </details>
          {hasMe && multipleSpeakers && (
            <label className="mr-2 flex items-center gap-1.5 text-xs text-muted-foreground">
              <input
                type="checkbox"
                checked={filterMe}
                disabled={!canFilterMe}
                title={
                  canFilterMe
                    ? "Show clear matches to your voice"
                    : "Switch to Original to filter speaker-labeled recognition"
                }
                onChange={(event) => setOnlyMe(event.target.checked)}
              />{" "}
              Only me
            </label>
          )}
          {!raw && !editing && (
            <>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Polish transcript"
                title={
                  meeting.document?.author === "user"
                    ? "Your edited document is kept as written"
                    : "Repair grammar and remove fillers without changing meaning"
                }
                disabled={
                  provisional ||
                  busy.has("runAssistant") ||
                  meeting.status === "processing" ||
                  meeting.document?.author === "user"
                }
                onClick={() => void act("runAssistant", { anticipate: false })}
              >
                {busy.has("runAssistant") ? (
                  <LoaderCircle className="animate-spin" />
                ) : (
                  <Sparkles />
                )}
              </Button>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Edit document"
                disabled={provisional}
                title={
                  provisional ? "Finish recognition before editing this draft" : "Edit document"
                }
                onClick={edit}
              >
                <PenLine />
              </Button>
            </>
          )}
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={copied ? "Copied" : "Copy transcript"}
            title={copied ? "Copied" : "Copy transcript"}
            onClick={() => void copy()}
          >
            {copied ? <Check /> : <Clipboard />}
          </Button>
        </div>
      </div>
      {provisional && (
        <div
          role="status"
          className="border-b px-6 py-3 text-xs leading-relaxed text-muted-foreground"
        >
          <p className="font-medium">
            Provisional recognition · Some recorded speech is still unresolved.
          </p>
          <p className="mt-1">
            These words were recovered from your audio. You can read or copy this draft while
            recognition remains retryable; it has not replaced an accepted transcript or become
            assistant evidence.
          </p>
          {!!meeting.recognitionDraft?.warnings.length && (
            <details className="mt-2">
              <summary className="cursor-pointer">Recognition details</summary>
              {meeting.recognitionDraft.warnings.map((warning) => (
                <p key={warning} className="mt-1">
                  {warning}
                </p>
              ))}
            </details>
          )}
        </div>
      )}
      <div
        ref={scroll}
        className="transcript-scroll document-scroll"
        onWheel={(event) => {
          if (event.deltaY < -10) setFollow(false)
        }}
      >
        {editing ? (
          <div className="document-editor">
            <Textarea
              aria-label="Edit transcript document"
              autoFocus
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              className="min-h-80"
            />
            <div className="mt-3 flex justify-end gap-2">
              <Button variant="ghost" size="sm" onClick={() => setEditing(false)}>
                <X />
                Cancel
              </Button>
              <Button
                size="sm"
                disabled={!draft.trim() || busy.has("editDocument")}
                onClick={() => void save()}
              >
                <Check />
                Save document
              </Button>
            </div>
            <p className="mt-3 text-xs leading-relaxed text-muted-foreground">
              Your edits are kept separately. Original transcription and audio are preserved.
            </p>
          </div>
        ) : (
          <ContextActions
            disabled={renaming?.meetingID === meeting.id}
            onOpen={() => setContextSelection(window.getSelection()?.toString() ?? "")}
            actions={[
              {
                label: "Copy selected text",
                disabled: !contextSelection,
                run: () => {
                  void act("copyText", { text: contextSelection })
                },
              },
              {
                label: "Copy transcript",
                run: () => {
                  void copy()
                },
              },
              { label: "Edit transcript…", disabled: provisional, separator: true, run: edit },
              {
                label: "Polish transcript",
                disabled: provisional || meeting.status === "recording" || busy.has("runAssistant"),
                run: () => {
                  void act("runAssistant", { anticipate: false })
                },
              },
            ]}
          >
            <article
              aria-busy={meeting.status === "processing"}
              className="transcript-document"
              aria-label={raw ? "Original transcript document" : "Repaired transcript document"}
            >
              {shown.length ? (
                shown.map((paragraph, index) => (
                  <p key={paragraph.id} className="passage-text">
                    {paragraph.speaker &&
                      paragraph.speaker !== "Note" &&
                      (index === 0 || shown[index - 1]?.speaker !== paragraph.speaker) && (
                        <span className="mb-1 flex items-center gap-1 text-xs font-medium text-muted-foreground">
                          {renaming?.meetingID === meeting.id &&
                          renaming.paragraphID === paragraph.id ? (
                            <>
                              <Input
                                autoFocus
                                aria-label={`Name for ${speakerName(paragraph.speaker)}`}
                                value={speakerDraft}
                                maxLength={80}
                                className="h-7 w-44 text-xs"
                                disabled={busy.has("renameSpeaker")}
                                onChange={(event) => setSpeakerDraft(event.target.value)}
                                onKeyDown={(event) => {
                                  if (event.key === "Enter") {
                                    event.preventDefault()
                                    void saveSpeaker()
                                  } else if (event.key === "Escape") setRenaming(null)
                                }}
                              />
                              <Button
                                variant="ghost"
                                size="icon-xs"
                                aria-label="Save speaker name"
                                disabled={busy.has("renameSpeaker")}
                                onClick={() => void saveSpeaker()}
                              >
                                <Check />
                              </Button>
                              <Button
                                variant="ghost"
                                size="icon-xs"
                                aria-label="Cancel renaming"
                                onClick={() => setRenaming(null)}
                              >
                                <X />
                              </Button>
                            </>
                          ) : (
                            <ContextActions
                              actions={[
                                {
                                  label: "Rename participant…",
                                  run: () => {
                                    if (paragraph.speaker) rename(paragraph.speaker, paragraph.id)
                                  },
                                },
                                {
                                  label: "Copy name",
                                  run: () => {
                                    if (paragraph.speaker)
                                      void act("copyText", { text: speakerName(paragraph.speaker) })
                                  },
                                },
                              ]}
                            >
                              <button
                                type="button"
                                className="cursor-text text-left hover:text-primary-ink hover:underline"
                                title={`Rename ${speakerName(paragraph.speaker)}`}
                                aria-label={`Rename speaker ${speakerName(paragraph.speaker)}`}
                                onClick={() => {
                                  const speaker = paragraph.speaker
                                  if (!speaker) return
                                  rename(speaker, paragraph.id)
                                }}
                              >
                                {speakerName(paragraph.speaker)}
                              </button>
                            </ContextActions>
                          )}
                        </span>
                      )}
                    {raw && paragraph.segments.length
                      ? paragraph.segments.map((segment) => (
                          <span
                            id={
                              firstRunBySource.get(segment.id) === segment.presentationID
                                ? `segment-${segment.id}`
                                : undefined
                            }
                            data-source-segment={segment.id}
                            key={segment.presentationID}
                          >
                            {segment.rawText}{" "}
                          </span>
                        ))
                      : paragraph.text}
                  </p>
                ))
              ) : (
                <div className="py-12 text-center">
                  <Search className="mx-auto size-5 text-muted-foreground" />
                  <h3 className="mt-3 text-base">No passages match “{search}”</h3>
                  <p className="mt-2 text-sm text-muted-foreground">
                    Try another word or clear the search.
                  </p>
                </div>
              )}
            </article>
          </ContextActions>
        )}
        {meeting.status === "recording" && (
          <div className="document-listening">
            <span className="live-dot !size-1.5" />
            <span>Listening…</span>
          </div>
        )}
        {!follow && meeting.status === "recording" && (
          <Button
            variant="secondary"
            size="sm"
            className="sticky bottom-2 mx-auto flex"
            onClick={() => setFollow(true)}
          >
            <ArrowDownToLine />
            Follow conversation
          </Button>
        )}
      </div>
    </div>
  )
}

export function AudioLevel({ value, label }: { value: number; label: string }) {
  const bars = Array.from({ length: 12 }, (_, index) => index)
  return (
    <div
      className="flex items-center gap-2"
      role="img"
      aria-label={`${label} level ${Math.round(value * 100)} percent`}
    >
      <Mic className="size-3.5 text-muted-foreground" />
      <span className="flex h-4 items-center gap-0.5">
        {bars.map((bar) => (
          <span
            key={bar}
            className={cn(
              "w-0.5 rounded-full transition-colors",
              value * 12 > bar ? "bg-primary" : "bg-border-strong"
            )}
            style={{ height: `${6 + (bar % 3) * 3}px` }}
          />
        ))}
      </span>
      <span className="text-xs text-muted-foreground">{label}</span>
    </div>
  )
}

export function EmptyTranscript({
  state,
  act,
  busy,
  open,
}: {
  state: AppState
  act: Act
  busy: Set<string>
  open: (name: ModalName) => void
}) {
  const ready = state.runtime.modelStatus === "ready"
  const native = state.runtime.native
  return (
    <div className="empty-transcript">
      <div className="listening-orbit">
        <div className="orbit orbit-one" />
        <div className="orbit orbit-two" />
        <AudioLines className="orbit-symbol size-8 text-primary" />
      </div>
      <Eyebrow>Your next conversation</Eyebrow>
      <h2 className="mt-4 text-[28px] leading-tight">Stay with the conversation.</h2>
      <p className="mt-4 max-w-[32em] text-sm leading-relaxed text-muted-foreground">
        Record both sides of a call, follow a local transcript, and keep useful context beside you.
      </p>
      <div className="mt-7 flex flex-wrap justify-center gap-2">
        <Button
          size="lg"
          onClick={() => {
            if (!state.meeting) open("new")
            else if (!native || !ready) open("settings")
            else void act("startRecording")
          }}
          disabled={busy.has("startRecording")}
        >
          <Mic />
          {!state.meeting
            ? "New meeting"
            : ready && native
              ? "Start recording"
              : "Set up local transcription"}
        </Button>
        <Button
          variant="outline"
          size="lg"
          onClick={() => (state.meeting ? open("passage") : open("new"))}
          className={!state.meeting ? "hidden" : undefined}
        >
          <PenLine />
          {state.meeting ? "Add a passage" : "Start with a brief"}
        </Button>
      </div>
      <div className="mt-9 flex flex-wrap justify-center gap-x-5 gap-y-2 text-xs text-muted-foreground">
        <span className="flex items-center gap-1.5">
          <ShieldCheck className="size-3.5" />
          Audio stays on your Mac
        </span>
        <span className="flex items-center gap-1.5">
          <Languages className="size-3.5" />
          English & Español
        </span>
      </div>
    </div>
  )
}
