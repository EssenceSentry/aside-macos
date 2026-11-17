import {
  ArrowDownToLine,
  AudioLines,
  Check,
  FolderOpen,
  Headphones,
  LoaderCircle,
  PenLine,
  Play,
  Plus,
  RefreshCw,
  UserRound,
  X,
} from "lucide-react"
import { type FormEvent, useEffect, useRef, useState } from "react"
import { Eyebrow, StatusBadge } from "@/blocks/primitives"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Switch } from "@/components/ui/switch"
import { Textarea } from "@/components/ui/textarea"
import { documentSpeakers } from "@/lib/document"
import type { AppState, Meeting, Segment, VoiceProfile } from "@/lib/types"

import { type Act, Field, LanguageSelect } from "@/screens/shared"

export function MeetingForm({
  meeting,
  state,
  act,
  close,
}: {
  meeting?: Meeting
  state: AppState
  act: Act
  close: () => void
}) {
  const [title, setTitle] = useState(meeting?.title ?? "")
  const [context, setContext] = useState(meeting?.context ?? "")
  const [startIncomplete, setStartIncomplete] = useState(meeting?.startIncomplete ?? false)
  const [language, setLanguage] = useState(meeting?.language ?? state.settings.language)
  const [documents, setDocuments] = useState(meeting?.documentIDs ?? [])
  const previousDocuments = useRef(meeting?.documentIDs ?? [])
  useEffect(() => {
    const incoming = meeting?.documentIDs ?? []
    const added = incoming.filter((id) => !previousDocuments.current.includes(id))
    if (added.length > 0) setDocuments((current) => [...new Set([...current, ...added])])
    previousDocuments.current = incoming
  }, [meeting?.documentIDs])
  const [saving, setSaving] = useState(false)
  async function submit(event: FormEvent) {
    event.preventDefault()
    setSaving(true)
    const okay = await act(meeting ? "updateMeeting" : "createMeeting", {
      title: title.trim() || "Untitled meeting",
      context,
      language,
      startIncomplete,
      ...(meeting ? { documentIDs: documents } : {}),
    })
    setSaving(false)
    if (okay) close()
  }
  return (
    <form onSubmit={submit} className="grid gap-5">
      <Field label="Meeting name">
        <Input
          autoFocus
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          placeholder="A name to find it by later"
          className="h-10"
        />
      </Field>
      <Field
        label="What would you like to accomplish?"
        hint="Give the assistant a brief, a question, or a little background."
      >
        <Textarea
          value={context}
          onChange={(event) => setContext(event.target.value)}
          placeholder="We're discussing… I'd like to leave with…"
          className="min-h-28"
        />
      </Field>
      <label className="flex items-center gap-2.5 text-sm">
        <input
          type="checkbox"
          checked={startIncomplete}
          onChange={(event) => setStartIncomplete(event.target.checked)}
        />
        The recording starts after the meeting began
      </label>
      <Field label="Language">
        <LanguageSelect value={language} onChange={setLanguage} />
      </Field>
      {meeting && state.documents.length > 0 && (
        <fieldset className="grid gap-2">
          <legend className="mb-2 text-sm font-medium">Documents for this meeting</legend>
          {state.documents.map((doc) => (
            <label key={doc.id} className="flex items-center gap-2.5 text-sm">
              <input
                type="checkbox"
                checked={documents.includes(doc.id)}
                onChange={(event) =>
                  setDocuments(
                    event.target.checked
                      ? [...documents, doc.id]
                      : documents.filter((id) => id !== doc.id)
                  )
                }
              />
              {doc.name}
            </label>
          ))}
        </fieldset>
      )}
      <div className="flex justify-end gap-2 pt-1">
        <Button variant="ghost" onClick={close}>
          Cancel
        </Button>
        <Button type="submit" disabled={saving}>
          {saving ? <LoaderCircle className="animate-spin" /> : <Check />}
          {meeting ? "Save meeting context" : "Create meeting"}
        </Button>
      </div>
    </form>
  )
}

export function PassageForm({
  segment,
  act,
  close,
}: {
  segment?: Segment
  act: Act
  close: () => void
}) {
  const [text, setText] = useState(segment?.text ?? "")
  const [remember, setRemember] = useState(false)
  const [term, setTerm] = useState("")
  const [alias, setAlias] = useState("")
  const [saving, setSaving] = useState(false)
  async function submit(event: FormEvent) {
    event.preventDefault()
    setSaving(true)
    const okay = await act(
      segment ? "editSegment" : "addPassage",
      segment ? { id: segment.id, text, revision: segment.revision } : { text, speaker: "You" }
    )
    if (okay && remember && segment)
      await act("learnCorrection", {
        segmentID: segment.id,
        revision: segment.revision + 1,
        term,
        alias,
        definition: "Confirmed from your transcript correction.",
      })
    setSaving(false)
    if (okay) close()
  }
  return (
    <form onSubmit={submit} className="grid gap-4">
      <Field
        label={segment ? "Your correction" : "Passage or note"}
        hint={
          segment
            ? "The original transcription stays in the record. The assistant will preserve your edit."
            : "Add something you want in the record, or paste a passage to try the assistant."
        }
      >
        <Textarea
          autoFocus
          value={text}
          onChange={(event) => setText(event.target.value)}
          className="min-h-40"
          placeholder="Add the passage here…"
        />
      </Field>
      {segment && (
        <div className="rounded-lg bg-sunken p-3">
          <Eyebrow>Original transcription</Eyebrow>
          <p className="mt-2 text-sm leading-relaxed text-ink-2">{segment.rawText}</p>
        </div>
      )}
      {segment && (
        <div className="rounded-lg border p-3">
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={remember}
              onChange={(event) => setRemember(event.target.checked)}
            />
            Remember a term from this correction
          </label>
          {remember && (
            <div className="mt-4 grid gap-3">
              <Field label="Correct term">
                <Input
                  value={term}
                  onChange={(event) => setTerm(event.target.value)}
                  placeholder="Parakeet"
                />
              </Field>
              <Field label="What was misheard">
                <Input
                  value={alias}
                  onChange={(event) => setAlias(event.target.value)}
                  placeholder="para kit"
                />
              </Field>
              <p className="text-xs leading-relaxed text-muted-foreground">
                Use the exact wording from the corrected and original passages. Your existing
                vocabulary stays unchanged.
              </p>
            </div>
          )}
        </div>
      )}
      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={close}>
          Cancel
        </Button>
        <Button
          type="submit"
          disabled={!text.trim() || saving || (remember && (!term.trim() || !alias.trim()))}
        >
          {saving && <LoaderCircle className="animate-spin" />}
          {segment ? "Save correction" : "Add passage"}
        </Button>
      </div>
    </form>
  )
}

export function GlossaryForm({ act, close }: { act: Act; close: () => void }) {
  const [term, setTerm] = useState("")
  const [aliases, setAliases] = useState("")
  const [definition, setDefinition] = useState("")
  async function submit(event: FormEvent) {
    event.preventDefault()
    if (
      await act("addGlossary", {
        term,
        aliases: aliases
          .split(",")
          .map((value) => value.trim())
          .filter(Boolean),
        definition,
      })
    )
      close()
  }
  return (
    <form onSubmit={submit} className="grid gap-5">
      <Field label="Term or name">
        <Input
          autoFocus
          value={term}
          onChange={(event) => setTerm(event.target.value)}
          placeholder="e.g. Parakeet"
          className="h-10"
        />
      </Field>
      <Field
        label="Possible mishearings"
        hint="Separate alternatives with commas. These help resolve plausible matches."
      >
        <Input
          value={aliases}
          onChange={(event) => setAliases(event.target.value)}
          placeholder="para kit, parakeets"
          className="h-10"
        />
      </Field>
      <Field label="Meaning in your work">
        <Textarea
          value={definition}
          onChange={(event) => setDefinition(event.target.value)}
          placeholder="What does it refer to?"
        />
      </Field>
      <div className="flex justify-end">
        <Button type="submit" disabled={!term.trim()}>
          <Plus />
          Add to glossary
        </Button>
      </div>
    </form>
  )
}

export function SettingsPanel({
  state,
  act,
  busy,
}: {
  state: AppState
  act: Act
  busy: Set<string>
}) {
  const [workContext, setWorkContext] = useState(state.settings.workContext ?? "")
  useEffect(() => setWorkContext(state.settings.workContext ?? ""), [state.settings.workContext])
  return (
    <div className="grid gap-6">
      <section className="border-b pb-5">
        <h3 className="text-sm font-semibold">Speakers and your voice</h3>
        <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
          Match saved voices during live captions and final recognition. A solo recording of you
          lets Aside label your speech as You. Ambiguous matches keep anonymous labels. Voice
          samples stay on this Mac; voice audio is never sent to a cloud provider.
        </p>
        <div className="mt-3 flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={
              !state.runtime.native ||
              busy.has("downloadSpeakerModel") ||
              state.runtime.speakerModelStatus === "ready"
            }
            onClick={() => void act("downloadSpeakerModel")}
          >
            {busy.has("downloadSpeakerModel") ? (
              <LoaderCircle className="animate-spin" />
            ) : (
              <Headphones />
            )}
            {state.runtime.speakerModelStatus === "ready"
              ? "Speaker model ready"
              : "Download speaker model"}
          </Button>
          <Button
            size="sm"
            variant="outline"
            disabled={
              !state.runtime.native || state.runtime.recording || busy.has("importVoiceReference")
            }
            onClick={() => void act("importVoiceReference")}
          >
            <FolderOpen />
            {state.runtime.voiceReferenceReady
              ? "Replace my voice sample"
              : "Learn my voice from a recording"}
          </Button>
        </div>
        <p className="mt-2 text-xs text-muted-foreground">
          {!state.runtime.native
            ? "Import voice samples in the Mac app."
            : state.runtime.recording
              ? "Finish recording before importing a voice sample."
              : state.runtime.voiceReferenceReady
                ? "Your voice sample is saved."
                : "Choose 8–120 seconds containing only your voice."}
        </p>
        <label
          htmlFor="speaker-identification"
          className="mt-4 flex items-center justify-between gap-4"
        >
          <span className="text-sm">Identify speakers during recognition</span>
          <Switch
            id="speaker-identification"
            aria-label="Identify speakers during recognition"
            checked={state.settings.identifySpeakers ?? true}
            disabled={state.runtime.recording}
            onCheckedChange={(value) => void act("updateSettings", { identifySpeakers: value })}
          />
        </label>
      </section>
      <SavedPeople state={state} act={act} busy={busy} />
      <section className="rounded-xl border bg-sunken p-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-sm font-semibold">Local speech recognition</h3>
            <p className="mt-1 text-xs text-muted-foreground">Parakeet v3 · English and Spanish</p>
          </div>
          <Headphones className="size-5 text-primary" />
        </div>
        <p className="mt-3 text-xs leading-relaxed text-ink-2">
          {state.runtime.modelMessage ||
            "Download the speech model once. Transcription then runs on your Mac."}
        </p>
        <Button
          className="mt-4"
          size="sm"
          disabled={
            !state.runtime.native ||
            state.runtime.modelStatus === "downloading" ||
            busy.has("downloadModel") ||
            state.runtime.modelStatus === "ready"
          }
          onClick={() => void act("downloadModel")}
        >
          {state.runtime.modelStatus === "downloading" || busy.has("downloadModel") ? (
            <LoaderCircle className="animate-spin" />
          ) : state.runtime.modelStatus === "ready" ? (
            <Check />
          ) : (
            <ArrowDownToLine />
          )}
          {state.runtime.modelStatus === "ready"
            ? "Model ready"
            : state.runtime.modelStatus === "downloading" || busy.has("downloadModel")
              ? "Preparing speech model…"
              : state.runtime.native
                ? "Download speech model"
                : "Available in the Mac app"}
        </Button>
        <label
          htmlFor="contextual-captions"
          className="mt-4 flex items-center justify-between gap-4"
        >
          <span>
            <span className="text-sm">Use context for live captions</span>
            <span className="mt-1 block text-xs leading-relaxed text-muted-foreground">
              Uses recent audio to recognize complete phrases. Captions appear as stable passages.
            </span>
          </span>
          <Switch
            id="contextual-captions"
            aria-label="Use context for live captions"
            checked={state.settings.contextualCaptions ?? true}
            disabled={state.runtime.recording}
            onCheckedChange={(value) => void act("updateSettings", { contextualCaptions: value })}
          />
        </label>
      </section>
      <section className="rounded-xl border p-4">
        <h3 className="text-sm font-semibold">Final recognition pass</h3>
        <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
          After recording, recognize the saved audio with more context. You can optionally shorten
          long silences. Original audio and earlier transcripts are kept. The first pass downloads a
          small local speech activity model.
        </p>
        <Button
          className="mt-3"
          size="sm"
          variant="outline"
          disabled={
            !state.runtime.native ||
            state.runtime.finalModelStatus === "ready" ||
            busy.has("downloadFinalModel")
          }
          onClick={() => void act("downloadFinalModel")}
        >
          {busy.has("downloadFinalModel") ? (
            <LoaderCircle className="animate-spin" />
          ) : (
            <ArrowDownToLine />
          )}
          {state.runtime.finalModelStatus === "ready"
            ? "Whisper Turbo ready"
            : busy.has("downloadFinalModel")
              ? "Preparing Whisper Turbo…"
              : "Download Whisper Turbo"}
        </Button>
        <p className="mt-2 text-xs text-muted-foreground">
          Local final-pass model, about 1.6 GB. Live captions continue with Parakeet. Until
          downloaded, final recognition uses Parakeet.
        </p>
        <label htmlFor="audio-pauses" className="mt-4 flex items-center justify-between gap-4">
          <span>
            <span className="text-sm">Shorten long pauses</span>
            <span className="mt-1 block text-xs text-muted-foreground">
              Optional preparation. Whisper uses the original audio by default.
            </span>
          </span>
          <Switch
            id="audio-pauses"
            aria-label="Shorten long pauses before recognition"
            checked={
              state.settings.shortenAudioPauses ?? state.runtime.finalModelStatus !== "ready"
            }
            disabled={state.runtime.recording}
            onCheckedChange={(value) => void act("updateSettings", { shortenAudioPauses: value })}
          />
        </label>
        <label htmlFor="audio-fillers" className="mt-4 flex items-center justify-between gap-4">
          <span>
            <span className="text-sm">Reduce hesitation sounds</span>
            <span className="mt-1 block text-xs leading-relaxed text-muted-foreground">
              Experimental: mask model-detected um/uh sounds before recognizing again. May remove a
              misrecognized word. Test on your own recordings.
            </span>
          </span>
          <Switch
            id="audio-fillers"
            checked={state.settings.reduceAudioFillers ?? false}
            disabled={state.runtime.recording}
            onCheckedChange={(value) => void act("updateSettings", { reduceAudioFillers: value })}
            aria-label="Reduce hesitation sounds before recognition"
          />
        </label>
      </section>
      <details className="rounded-xl border p-4">
        <summary className="cursor-pointer text-sm font-semibold">Shared work context</summary>
        <p className="mt-3 text-xs leading-relaxed text-muted-foreground">
          A short brief about your work, shared with your provider for transcript repair,
          preparation and questions. It helps with terminology; it is not a record of this meeting.
          You can edit it here. The brief stays in your local workspace until an assistant request
          uses it.
        </p>
        <Textarea
          className="mt-3 min-h-80 text-sm"
          aria-label="Shared work context"
          value={workContext}
          disabled={busy.has("regenerateMemory")}
          maxLength={16000}
          onChange={(event) => setWorkContext(event.target.value)}
        />
        <div className="mt-3 flex items-center justify-between gap-3">
          <span className="text-xs text-muted-foreground">
            {workContext.trim().split(/\s+/).filter(Boolean).length} words
          </span>
          <Button
            size="sm"
            disabled={
              busy.has("regenerateMemory") ||
              busy.has("updateSettings") ||
              workContext === (state.settings.workContext ?? "")
            }
            onClick={() => void act("updateSettings", { workContext })}
          >
            Save work context
          </Button>
        </div>
        <div className="mt-4 border-t pt-4">
          <Button
            variant="outline"
            size="sm"
            disabled={
              !state.runtime.native ||
              state.runtime.recording ||
              busy.has("regenerateMemory") ||
              workContext !== (state.settings.workContext ?? "")
            }
            onClick={() => void act("regenerateMemory")}
          >
            {busy.has("regenerateMemory") ? (
              <LoaderCircle className="animate-spin" />
            ) : (
              <RefreshCw />
            )}
            {busy.has("regenerateMemory") ? "Regenerating memory…" : "Regenerate memory"}
          </Button>
          <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
            Reads local Claude and Codex memory notes and consolidates them through your selected
            assistant provider. Full chats are excluded. Your previous brief is saved. Save any
            edits before regenerating.
          </p>
          {busy.has("regenerateMemory") && (
            <p role="status" className="mt-2 text-xs text-primary">
              {state.runtime.assistantStatus}
            </p>
          )}
          {state.runtime.lastError && (
            <p role="alert" className="mt-2 text-xs text-bad">
              {state.runtime.lastError}
            </p>
          )}
        </div>
      </details>
      <div>
        <h3 className="mb-4 text-sm font-semibold">Meeting assistant</h3>
        <label htmlFor="assistant-enabled" className="flex items-center justify-between gap-4">
          <span>
            <span className="text-sm">Stay alongside the conversation</span>
            <span className="mt-1 block text-xs leading-relaxed text-muted-foreground">
              Repair recent passages and prepare useful context.
            </span>
          </span>
          <Switch
            id="assistant-enabled"
            checked={state.settings.assistantEnabled}
            onCheckedChange={(value) => void act("updateSettings", { assistantEnabled: value })}
            aria-label="Enable meeting assistant"
          />
        </label>
        <div className="mt-4">
          <Field label="During meetings">
            <select
              className="aside-select"
              value={state.settings.provider}
              onChange={(event) => void act("updateSettings", { provider: event.target.value })}
            >
              <option value="claude-cli">Haiku through Claude Code</option>
              <option value="codex-cli">Luna through Codex</option>
            </select>
          </Field>
          <div className="mt-3">
            <Field label="Final transcript after the meeting">
              <select
                className="aside-select"
                value={state.settings.finalProvider ?? "codex-terra"}
                onChange={(event) =>
                  void act("updateSettings", { finalProvider: event.target.value })
                }
              >
                <option value="codex-terra">Terra through Codex</option>
                <option value="claude-cli">Haiku through Claude Code</option>
                <option value="codex-cli">Luna through Codex</option>
              </select>
            </Field>
          </div>
          <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
            Uses your installed CLI login. Selected transcript passages and document excerpts are
            sent to your provider. Audio stays local.
          </p>
          <div className="mt-3">
            <StatusBadge
              status={
                state.runtime.providerAvailable && state.runtime.finalProviderAvailable !== false
                  ? "succeeded"
                  : "warning"
              }
              label={
                state.runtime.providerAvailable && state.runtime.finalProviderAvailable !== false
                  ? "Meeting and final writers available"
                  : "Install or sign in to the selected CLIs"
              }
            />
          </div>
        </div>
      </div>
      <div className="border-t pt-5">
        <label htmlFor="system-audio-enabled" className="flex items-center justify-between gap-4">
          <span>
            <span className="text-sm">Capture meeting audio</span>
            <span className="mt-1 block text-xs leading-relaxed text-muted-foreground">
              Save the other side of a call separately from your microphone.
            </span>
          </span>
          <Switch
            id="system-audio-enabled"
            checked={state.settings.captureSystemAudio}
            disabled={state.runtime.recording}
            onCheckedChange={(value) => void act("updateSettings", { captureSystemAudio: value })}
            aria-label="Capture system audio"
          />
        </label>
        <div className="mt-2 text-xs leading-relaxed text-muted-foreground">
          macOS must also allow Aside in Privacy &amp; Security → Screen &amp; System Audio
          Recording.
          <Button
            variant="link"
            size="xs"
            className="h-auto px-0"
            disabled={!state.runtime.native}
            onClick={() => void act("openSystemAudioSettings")}
          >
            Open macOS recording permissions
          </Button>
        </div>
        {state.runtime.recording && (
          <p className="mt-2 text-xs text-muted-foreground">
            Stop recording to change audio sources.
          </p>
        )}
      </div>
      <Field label="Default language">
        <LanguageSelect
          value={state.settings.language}
          onChange={(language) => void act("updateSettings", { language })}
        />
      </Field>
      <div className="grid grid-cols-2 gap-4">
        <Field label="Repair cadence">
          <select
            className="aside-select"
            value={state.settings.repairInterval}
            onChange={(event) =>
              void act("updateSettings", { repairInterval: Number(event.target.value) })
            }
          >
            <option value="15">Every 15 seconds</option>
            <option value="30">Every 30 seconds</option>
            <option value="60">Every 60 seconds</option>
          </select>
        </Field>
        <Field label="Preparation cadence">
          <select
            className="aside-select"
            value={state.settings.anticipationInterval}
            onChange={(event) =>
              void act("updateSettings", { anticipationInterval: Number(event.target.value) })
            }
          >
            <option value="25">Every 25 seconds</option>
            <option value="45">Every 45 seconds</option>
            <option value="60">Every 60 seconds</option>
          </select>
        </Field>
      </div>
      <div className="flex flex-wrap items-center justify-between gap-3 border-t pt-4">
        <span className="text-xs text-muted-foreground">
          {state.runtime.totalCalls} assistant calls this session
        </span>
        <Button
          variant="outline"
          size="sm"
          disabled={!state.runtime.native}
          onClick={() => void act("revealData")}
        >
          <FolderOpen />
          Show local files
        </Button>
      </div>
    </div>
  )
}

function SavedPeople({ state, act, busy }: { state: AppState; act: Act; busy: Set<string> }) {
  const [name, setName] = useState("")
  const [importing, setImporting] = useState(false)
  const [activeProfile, setActiveProfile] = useState<string | null>(null)
  const [editingProfile, setEditingProfile] = useState<{ id: string; name: string } | null>(null)
  const profiles = state.voiceProfiles ?? []
  const existing = profiles.find(
    (profile) => profile.name.toLowerCase() === name.trim().toLowerCase()
  )
  async function importSample() {
    setImporting(true)
    await act("importVoiceProfile", { name: name.trim() })
    setImporting(false)
  }
  async function renameProfile(event: FormEvent, profile: VoiceProfile) {
    event.preventDefault()
    if (!editingProfile?.name.trim()) return
    setActiveProfile(profile.id)
    const okay = await act("renameVoiceProfile", {
      id: profile.id,
      name: editingProfile.name.trim(),
    })
    setActiveProfile(null)
    if (okay) setEditingProfile(null)
  }
  async function profileAction(action: string, profile: VoiceProfile, enabled?: boolean) {
    setActiveProfile(profile.id)
    await act(action, { id: profile.id, ...(enabled === undefined ? {} : { enabled }) })
    setActiveProfile(null)
  }
  return (
    <section className="rounded-xl border p-4">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h3 className="text-sm font-semibold">Saved people</h3>
          <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
            Keep voice references for people you meet regularly. Remember an identified speaker from
            a meeting, or import a solo recording here.
          </p>
        </div>
        <UserRound className="size-5 shrink-0 text-primary" />
      </div>
      {profiles.length > 0 ? (
        <ul className="mt-4 divide-y rounded-lg border bg-sunken px-3">
          {profiles.map((profile) => {
            const seconds = Math.round(
              profile.samples.reduce((sum, sample) => sum + sample.duration, 0)
            )
            const duration =
              seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`
            return (
              <li
                key={profile.id}
                className="flex flex-wrap items-center justify-between gap-3 py-3"
              >
                <div className="min-w-0 flex-1 basis-40">
                  <p className="break-words text-sm font-medium">{profile.name}</p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {profile.samples.length} {profile.samples.length === 1 ? "sample" : "samples"} ·{" "}
                    {duration} saved
                  </p>
                  {editingProfile?.id === profile.id && (
                    <form
                      className="mt-3 grid gap-2"
                      onSubmit={(event) => void renameProfile(event, profile)}
                    >
                      <Input
                        autoFocus
                        aria-label={`Name for ${profile.name}`}
                        value={editingProfile.name}
                        disabled={activeProfile !== null}
                        onChange={(event) =>
                          setEditingProfile({ id: profile.id, name: event.target.value })
                        }
                      />
                      <div className="flex flex-wrap gap-2">
                        <Button
                          type="submit"
                          size="sm"
                          disabled={
                            activeProfile !== null ||
                            !editingProfile.name.trim() ||
                            editingProfile.name.trim() === profile.name
                          }
                        >
                          {activeProfile === profile.id ? (
                            <LoaderCircle className="animate-spin" />
                          ) : (
                            <Check />
                          )}
                          Save name
                        </Button>
                        <Button
                          type="button"
                          size="sm"
                          variant="ghost"
                          disabled={activeProfile !== null}
                          onClick={() => setEditingProfile(null)}
                        >
                          Cancel
                        </Button>
                      </div>
                    </form>
                  )}
                </div>
                <div className="flex flex-wrap items-center gap-3">
                  <Button
                    size="icon-sm"
                    variant="ghost"
                    disabled={
                      !state.runtime.native || activeProfile !== null || editingProfile !== null
                    }
                    aria-label={`Rename voice profile for ${profile.name}`}
                    title={`Rename ${profile.name}`}
                    onClick={() => setEditingProfile({ id: profile.id, name: profile.name })}
                  >
                    <PenLine />
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={
                      !state.runtime.native || !profile.samples.length || activeProfile !== null
                    }
                    aria-label={`Play latest sample for ${profile.name}`}
                    onClick={() => void profileAction("playVoiceProfile", profile)}
                  >
                    <Play /> Play sample
                  </Button>
                  <label
                    htmlFor={`voice-profile-${profile.id}`}
                    className="flex items-center gap-2 text-xs"
                  >
                    Use voice
                    <Switch
                      id={`voice-profile-${profile.id}`}
                      aria-label={`Use voice reference for ${profile.name}`}
                      checked={profile.enabled}
                      disabled={
                        !state.runtime.native ||
                        activeProfile !== null ||
                        busy.has("setVoiceProfileEnabled")
                      }
                      onCheckedChange={(enabled) =>
                        void profileAction("setVoiceProfileEnabled", profile, enabled)
                      }
                    />
                  </label>
                </div>
              </li>
            )
          })}
        </ul>
      ) : (
        <p className="mt-4 rounded-lg bg-sunken p-3 text-xs leading-relaxed text-muted-foreground">
          No saved people yet. A name and a solo voice sample give Aside a reference for future
          meetings.
        </p>
      )}
      <div className="mt-4 grid gap-3">
        <Field label="Person’s name">
          <Input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="e.g. Alex Rivera"
          />
        </Field>
        <div className="flex flex-wrap items-center gap-3">
          <Button
            size="sm"
            variant="outline"
            disabled={
              !state.runtime.native ||
              state.runtime.recording ||
              !name.trim() ||
              importing ||
              busy.has("importVoiceProfile")
            }
            onClick={() => void importSample()}
          >
            {importing ? <LoaderCircle className="animate-spin" /> : <FolderOpen />}
            {importing ? "Importing sample…" : "Import voice sample"}
          </Button>
          <p className="text-xs text-muted-foreground" aria-live="polite">
            {!state.runtime.native
              ? "Available in the Mac app."
              : state.runtime.recording
                ? "Finish recording to import."
                : existing
                  ? `Adds another sample to ${existing.name}.`
                  : "Choose 8–120 seconds of only this person’s voice."}
          </p>
        </div>
      </div>
      <p className="mt-3 text-xs leading-relaxed text-muted-foreground">
        Turning off Use voice keeps the samples and excludes them from future matches. Play sample
        uses the latest recording.
      </p>
    </section>
  )
}

export function SpeakerNamesForm({
  meeting,
  voiceProfiles = [],
  native = false,
  recording = false,
  act,
  close,
}: {
  meeting: Meeting
  voiceProfiles?: VoiceProfile[]
  native?: boolean
  recording?: boolean
  act: Act
  close: () => void
}) {
  const labels = [...documentSpeakers(meeting)]
  const captureLabels = new Set(meeting.audioTracks.map((track) => track.label))
  const rawSpeakers = new Set(
    meeting.segments
      .filter(
        (segment) =>
          segment.kind !== "note" && segment.status !== "manual" && segment.end > segment.start
      )
      .map((segment) => segment.speaker)
  )
  const canRemember = (label: string) =>
    rawSpeakers.has(label) &&
    meeting.audioTracks.length > 0 &&
    !captureLabels.has(label) &&
    label !== "You" &&
    label !== "Mixed speakers" &&
    !label.includes("+") &&
    !/unknown/i.test(label)
  const isHumanName = (name: string) =>
    Boolean(name.trim()) &&
    !/^(?:.* · )?(?:speaker\s*\d+|unknown(?: speaker)?|microphone|system audio|you)$/i.test(
      name.trim()
    ) &&
    !name.includes("+")
  const [names, setNames] = useState(meeting.speakerNames ?? {})
  const [saving, setSaving] = useState(false)
  const [remembering, setRemembering] = useState<string | null>(null)
  const [remembered, setRemembered] = useState<Record<string, string>>({})
  const enrollingUnavailable = !native || recording || meeting.status === "processing"
  async function remember(label: string) {
    const name = (names[label] ?? label).trim()
    setRemembering(label)
    const okay = await act("saveVoiceProfile", { speaker: label, name })
    setRemembering(null)
    if (okay) setRemembered((current) => ({ ...current, [label]: name }))
  }
  async function save(event: FormEvent) {
    event.preventDefault()
    setSaving(true)
    const okay = await act("updateMeeting", { speakerNames: names })
    setSaving(false)
    if (okay) close()
  }
  return (
    <form className="grid gap-4" onSubmit={save}>
      <p className="text-sm leading-relaxed text-muted-foreground">
        Rename the speakers shown in the written transcript and original recognition. Remember a
        voice to recognize this person in future meetings.
      </p>
      {labels.map((label) => {
        const name = (names[label] ?? label).trim()
        const profile = voiceProfiles.find(
          (value) => value.name.toLowerCase() === name.toLowerCase()
        )
        const saved = remembered[label] === name
        return (
          <div key={label} className="grid gap-2 rounded-lg border p-3">
            <Field label={label}>
              <Input
                value={names[label] ?? label}
                disabled={remembering === label}
                onChange={(event) =>
                  setNames((current) => ({ ...current, [label]: event.target.value }))
                }
              />
            </Field>
            {label === "You" && (
              <p className="text-xs leading-relaxed text-muted-foreground">
                Your own voice reference is managed under Speakers and your voice in Settings.
              </p>
            )}
            {!rawSpeakers.has(label) && label !== "You" && (
              <p className="text-xs leading-relaxed text-muted-foreground">
                This name applies to the displayed voice. Identify individual voices or import a
                solo recording to save a reference.
              </p>
            )}
            {canRemember(label) && (
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={
                    enrollingUnavailable ||
                    remembering !== null ||
                    saving ||
                    !isHumanName(name) ||
                    saved
                  }
                  aria-label={`${profile ? "Add voice sample" : "Remember voice"} for ${label}`}
                  onClick={() => void remember(label)}
                >
                  {remembering === label ? (
                    <LoaderCircle className="animate-spin" />
                  ) : saved ? (
                    <Check />
                  ) : (
                    <UserRound />
                  )}
                  {remembering === label
                    ? "Saving voice…"
                    : saved
                      ? "Voice saved"
                      : profile
                        ? "Add voice sample"
                        : "Remember voice"}
                </Button>
                <span className="text-xs text-muted-foreground" aria-live="polite">
                  {saved
                    ? `Saved for ${name}.`
                    : !native
                      ? "Available in the Mac app."
                      : enrollingUnavailable
                        ? "Finish recording and voice identification first."
                        : !isHumanName(name)
                          ? "Enter this person’s name first."
                          : profile
                            ? `Adds to ${profile.samples.length} saved ${profile.samples.length === 1 ? "sample" : "samples"}.`
                            : "Saves a clean clip from the original audio."}
                </span>
              </div>
            )}
          </div>
        )
      })}
      <p className="text-xs leading-relaxed text-muted-foreground">
        Only individual voices in the original recognition can be remembered. Capture labels,
        uncertain voices and names inferred only in the written transcript cannot supply a voice
        sample. Anonymous labels may change after reprocessing; saved name changes stay with that
        transcript.
      </p>
      <Button type="submit" disabled={saving || remembering !== null}>
        {saving ? <LoaderCircle className="animate-spin" /> : <Check />} Save speaker names
      </Button>
    </form>
  )
}

export function NarrationExport({
  state,
  act,
  busy,
}: {
  state: AppState
  act: Act
  busy: Set<string>
}) {
  const [voice, setVoice] = useState("you")
  const [language, setLanguage] = useState<"English" | "Spanish" | "auto">("English")
  const profiles = (state.voiceProfiles ?? []).filter(
    (profile) => profile.enabled && profile.samples.some((sample) => sample.duration >= 3)
  )
  const selectedProfile = profiles.find((profile) => profile.id === voice)
  const selectedVoice = voice === "you" || selectedProfile ? voice : "you"
  const hasVoice =
    selectedVoice === "you" ? state.runtime.voiceReferenceReady : Boolean(selectedProfile)
  const document = state.meeting?.document
  const hasDocument = Boolean(
    document?.text.trim() || document?.blocks?.some((block) => block.text.trim())
  )
  const preparing =
    busy.has("prepareNarration") || state.runtime.narrationModelStatus === "downloading"
  const rendering = busy.has("exportNarration")
  const working = preparing || rendering
  const ready = state.runtime.narrationModelStatus === "ready"
  const meetingBusy = state.runtime.recording || state.meeting?.status === "processing"
  const unavailable = !state.runtime.native || meetingBusy || working
  const guidance = !state.runtime.native
    ? "Narrated audio is available in the Mac app."
    : meetingBusy
      ? "Finish recording and transcript processing before narrating."
      : !hasDocument
        ? "Finish the written transcript before exporting narration."
        : !hasVoice
          ? "Import your voice sample under Speakers and your voice in Settings."
          : !ready
            ? "Prepare local narration once before the first export."
            : language === "English"
              ? "English delivery uses the selected voice with English pronunciation."
              : language === "Spanish"
                ? "Spanish delivery uses the selected voice with Spanish pronunciation."
                : "Delivery follows the language of the written transcript."
  return (
    <section className="mt-1 grid gap-3 border-t pt-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-semibold">Narrated transcript</h3>
        {ready && !working && <StatusBadge status="succeeded" label="Local model ready" />}
      </div>
      <p className="text-xs leading-relaxed text-muted-foreground">
        Read the current written transcript aloud in a saved voice. Synthesis runs on your Mac and
        produces a separate audio file from your captured recording.
      </p>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Narration voice">
          <select
            className="aside-select w-full min-w-0"
            value={selectedVoice}
            aria-label="Narration voice"
            disabled={unavailable}
            onChange={(event) => setVoice(event.target.value)}
          >
            <option value="you">
              Your voice{!state.runtime.voiceReferenceReady ? " · sample needed" : ""}
            </option>
            {profiles.map((profile) => (
              <option key={profile.id} value={profile.id}>
                {profile.name}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Narration language">
          <select
            className="aside-select w-full min-w-0"
            value={language}
            aria-label="Narration language"
            disabled={unavailable}
            onChange={(event) => setLanguage(event.target.value as typeof language)}
          >
            <option value="English">English</option>
            <option value="Spanish">Español</option>
            <option value="auto">Follow transcript</option>
          </select>
        </Field>
      </div>
      {!ready && (
        <div className="rounded-lg bg-sunken p-3">
          <p className="text-xs leading-relaxed text-muted-foreground">
            Downloads local speech tools and models once. Preparing the model can take several
            minutes.
          </p>
          <Button
            className="mt-3"
            size="sm"
            variant="outline"
            disabled={unavailable}
            onClick={() => void act("prepareNarration")}
          >
            {preparing ? <LoaderCircle className="animate-spin" /> : <ArrowDownToLine />}
            {preparing
              ? "Preparing local narration…"
              : state.runtime.narrationModelStatus === "error"
                ? "Retry local narration setup"
                : "Prepare local narration"}
          </Button>
        </div>
      )}
      <Button
        variant="outline"
        className="h-auto justify-between p-4"
        disabled={unavailable || !ready || !hasVoice || !hasDocument}
        onClick={() => void act("exportNarration", { voiceProfileID: selectedVoice, language })}
      >
        <span className="flex items-center gap-3">
          {rendering ? <LoaderCircle className="animate-spin" /> : <AudioLines />}
          <span>{rendering ? "Narrating transcript…" : "Narrated transcript · WAV"}</span>
        </span>
        {!rendering && <ArrowDownToLine />}
      </Button>
      {working && (
        <Button
          variant="ghost"
          size="sm"
          className="justify-self-start"
          disabled={busy.has("cancelNarration")}
          onClick={() => void act("cancelNarration")}
        >
          {busy.has("cancelNarration") ? <LoaderCircle className="animate-spin" /> : <X />}
          {busy.has("cancelNarration") ? "Cancelling narration…" : "Cancel narration"}
        </Button>
      )}
      <p className="text-xs leading-relaxed text-muted-foreground" aria-live="polite">
        {guidance}
      </p>
      {state.runtime.narrationMessage && (
        <p className="text-xs leading-relaxed text-ink-2" role="status">
          {state.runtime.narrationMessage}
        </p>
      )}
    </section>
  )
}
