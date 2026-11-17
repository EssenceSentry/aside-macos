import {
  ArrowRight,
  BookOpen,
  ChevronDown,
  CircleHelp,
  EyeOff,
  FileText,
  Lightbulb,
  LoaderCircle,
  MessageCircle,
  PanelRightOpen,
  PictureInPicture2,
  Sparkles,
  Square,
  X,
} from "lucide-react"
import { type FormEvent, useEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { Textarea } from "@/components/ui/textarea"
import type { AppState, AssistCard, Source } from "@/lib/types"
import { cn } from "@/lib/utils"

import type { Act } from "@/screens/shared"

export function Sources({ sources, act }: { sources: Source[]; act: Act }) {
  return (
    sources.length > 0 && (
      <details className="source-reference mt-3">
        <summary className="flex cursor-pointer items-center gap-2 text-xs text-primary-ink">
          <BookOpen className="size-3.5 shrink-0" />
          Sources · {sources.length}
          <ChevronDown className="ml-auto size-3 shrink-0" />
        </summary>
        <div className="mt-2 grid gap-2">
          {sources.map((source) => (
            <details
              key={`${source.documentID}-${source.location}-${source.excerpt}`}
              className="source-reference"
            >
              <summary className="flex cursor-pointer items-center gap-2 text-xs text-primary-ink">
                {source.documentID.startsWith("session:") ? (
                  <MessageCircle className="size-3.5 shrink-0" />
                ) : (
                  <FileText className="size-3.5 shrink-0" />
                )}
                <span className="min-w-0 break-words">
                  {source.title}
                  {source.location ? ` · ${source.location}` : ""}
                </span>
                <ChevronDown className="ml-auto size-3 shrink-0" />
              </summary>
              {source.excerpt && (
                <blockquote className="mt-2 border-l-2 pl-3 text-xs leading-relaxed text-ink-2">
                  {source.excerpt}
                </blockquote>
              )}
              <Button
                variant="link"
                size="xs"
                className="mt-1"
                onClick={() =>
                  source.segmentID || source.documentID.startsWith("meeting-document:")
                    ? window.dispatchEvent(
                        new CustomEvent("aside-inspect-source", { detail: source })
                      )
                    : void act("openSource", { documentID: source.documentID })
                }
              >
                {source.segmentID
                  ? "Show passage"
                  : source.documentID.startsWith("meeting-document:")
                    ? "Show corrected document"
                    : source.documentID.startsWith("session:")
                      ? "Open session"
                      : "Open document"}
                <ArrowRight />
              </Button>
            </details>
          ))}
        </div>
      </details>
    )
  )
}

export function InsightCard({ card, act }: { card: AssistCard; act: Act }) {
  const Icon =
    card.kind === "question" ? CircleHelp : card.kind === "reference" ? BookOpen : Lightbulb
  return (
    <article className="insight-card">
      <div className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-1.5 text-xs text-primary-ink">
          <Icon className="size-3.5" />
          {card.kind === "question"
            ? "May come up next"
            : card.kind === "reference"
              ? "Useful reference"
              : card.kind === "answer"
                ? "Prepared answer"
                : "Worth remembering"}
        </span>
        <Button
          size="icon-xs"
          variant="ghost"
          aria-label={`Dismiss ${card.title}`}
          onClick={() => void act("dismissCard", { id: card.id })}
        >
          <X />
        </Button>
      </div>
      <h3 className="mt-3 text-sm font-semibold leading-relaxed">{card.title}</h3>
      <p className="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-ink-2">{card.body}</p>
      {card.why && <p className="mt-3 text-xs leading-relaxed text-muted-foreground">{card.why}</p>}
      <Sources sources={card.sources} act={act} />
    </article>
  )
}

export function AssistantPane({
  state,
  act,
  busy,
  onContext,
  floating = false,
}: {
  state: AppState
  act: Act
  busy: Set<string>
  onContext: () => void
  floating?: boolean
}) {
  const [question, setQuestion] = useState("")
  const [localTab, setLocalTab] = useState<"ready" | "ask">("ready")
  const tab = state.runtime.assistantView ?? localTab
  const end = useRef<HTMLDivElement>(null)
  const meeting = state.meeting
  const cards = meeting?.cards.filter((card) => !card.dismissed && !card.superseded) ?? []
  const asking = busy.has("ask") || state.runtime.answering === true
  const thinking =
    asking ||
    busy.has("runAssistant") ||
    /thinking|listening|writing|repairing|reviewing|preparing|extracting|answering|polishing|finishing|consolidating|reading memories|recognizing|identifying|reconstructing/i.test(
      state.runtime.assistantStatus
    )
  const messageCount = meeting?.messages.length ?? 0
  useEffect(() => {
    if (tab === "ask" && messageCount > 0)
      end.current?.scrollIntoView({ block: "nearest", behavior: "smooth" })
  }, [messageCount, tab])
  function setTab(view: "ready" | "ask") {
    setLocalTab(view)
    if (state.runtime.native && state.runtime.assistantView !== view)
      void act("setAssistantView", { view })
  }
  async function ask(event: FormEvent) {
    event.preventDefault()
    if (!question.trim() || !meeting || asking) return
    const text = question
    setQuestion("")
    setTab("ask")
    if (!(await act("ask", { question: text }))) setQuestion(text)
  }
  return (
    <aside className="assistant-pane" aria-label="Meeting assistant">
      <div className="flex items-center justify-between gap-3 border-b px-5 py-4">
        <div className="flex items-center gap-2 text-sm font-semibold">
          <Sparkles className="size-4 text-primary" />
          Alongside you
        </div>
        <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
          {thinking ? (
            <LoaderCircle className="size-3 animate-spin" />
          ) : (
            <span className="size-1.5 rounded-full bg-primary" />
          )}
          {!state.runtime.native
            ? "Mac app required"
            : thinking
              ? "Thinking"
              : !state.settings.assistantEnabled
                ? "Paused"
                : !state.runtime.providerAvailable
                  ? "Not connected"
                  : "Ready"}
        </span>
        {state.runtime.native && (
          <div className="flex items-center gap-0.5">
            {floating && state.runtime.recording && (
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label="Stop recording"
                title="Stop recording and finish the transcript"
                disabled={busy.has("stopRecording")}
                onClick={() => void act("stopRecording")}
              >
                {busy.has("stopRecording") ? <LoaderCircle className="animate-spin" /> : <Square />}
              </Button>
            )}
            {floating && (
              <Button
                variant="ghost"
                size="icon-xs"
                aria-label="Hide contextual help"
                title="Hide contextual help · Show again from Aside or View → Floating help"
                onClick={() => void act("hideContext")}
              >
                <EyeOff />
              </Button>
            )}
            <Button
              variant="ghost"
              size="icon-xs"
              aria-label={floating ? "Return help to sidebar" : "Float contextual help"}
              title={
                floating
                  ? "Return help to Sidebar"
                  : "Picture in picture · Keep help above other apps"
              }
              onClick={() => void act(floating ? "dockContext" : "floatContext")}
            >
              {floating ? <PanelRightOpen /> : <PictureInPicture2 />}
            </Button>
          </div>
        )}
      </div>
      {thinking && (
        <p role="status" className="border-b px-5 py-2 text-xs text-muted-foreground">
          {asking ? "Answering your question" : state.runtime.assistantStatus}
        </p>
      )}
      <div className="flex gap-5 border-b px-5" role="tablist" aria-label="Assistant view">
        {(["ready", "ask"] as const).map((value) => (
          <button
            type="button"
            key={value}
            role="tab"
            aria-selected={tab === value}
            className={cn("pane-tab", tab === value && "active")}
            onClick={() => setTab(value)}
          >
            {value === "ready" ? "Ready for you" : "Ask anything"}
            {value === "ready" && cards.length > 0 && (
              <span className="ml-2 rounded bg-primary-soft px-1.5 text-primary-ink">
                {cards.length}
              </span>
            )}
          </button>
        ))}
      </div>
      <div className="assistant-content">
        {meeting && meeting.segments.length > 0 && tab === "ready" && (
          <Button
            variant="outline"
            size="sm"
            className="mb-4 w-full"
            disabled={thinking}
            onClick={() => void act("runAssistant", { repair: false, anticipate: true })}
          >
            <Sparkles />
            {thinking ? "Preparing context…" : "Prepare useful context"}
          </Button>
        )}
        {tab === "ready" ? (
          cards.length > 0 ? (
            <div className="grid gap-3">
              {cards.map((card) => (
                <InsightCard key={card.id} card={card} act={act} />
              ))}
            </div>
          ) : (
            <div className="assistant-empty">
              <div className="thought-mark">
                <Sparkles className="size-5" />
              </div>
              <h3 className="mt-5 text-base">A little ahead of the conversation.</h3>
              <p className="mt-3 text-sm leading-relaxed text-muted-foreground">
                As you talk, Aside prepares likely questions, useful references and answers
                connected to your recent work.
              </p>
              <div className="mt-6 rounded-xl border bg-sunken p-4 text-left">
                <div className="flex items-center gap-2 text-xs font-medium">
                  <BookOpen className="size-3.5 text-primary" />
                  Start with your context
                </div>
                <p className="mt-2 text-xs leading-relaxed text-muted-foreground">
                  Aside draws on your last four days of Claude and Codex sessions. Add a brief or
                  relevant documents to give this conversation more context.
                </p>
                <Button size="sm" variant="link" className="mt-3 h-auto px-0" onClick={onContext}>
                  Add meeting context
                  <ArrowRight />
                </Button>
              </div>
            </div>
          )
        ) : (
          <div className="grid gap-5">
            {!meeting?.messages.length && (
              <div className="py-6">
                <MessageCircle className="size-5 text-primary" />
                <h3 className="mt-4 text-base">Keep a thought within reach.</h3>
                <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                  Ask about this meeting, its documents or your recent Claude and Codex work.
                  Answers bring their sources with them.
                </p>
              </div>
            )}
            {meeting?.messages.map((message) => (
              <div
                key={message.id}
                className={cn("chat-message", message.role === "user" && "from-you")}
              >
                <span className="text-xs font-medium text-muted-foreground">
                  {message.role === "user" ? "You" : "Aside"}
                </span>
                <p className="mt-2 whitespace-pre-wrap text-sm leading-relaxed">{message.text}</p>
                <Sources sources={message.sources} act={act} />
              </div>
            ))}
            <div ref={end} />
          </div>
        )}
      </div>
      <form onSubmit={ask} className="assistant-question">
        <label htmlFor="ask-aside" className="sr-only">
          Ask Aside
        </label>
        <Textarea
          id="ask-aside"
          value={question}
          onFocus={() => setTab("ask")}
          onChange={(event) => setQuestion(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault()
              void ask(event)
            }
          }}
          placeholder={
            meeting
              ? "Ask about this meeting or your recent work…"
              : "Create a meeting to ask Aside"
          }
          disabled={!meeting || asking}
          className="min-h-20 resize-none border-0 bg-transparent p-0 text-sm shadow-none focus-visible:ring-0"
        />
        <div className="flex items-center justify-between gap-2">
          <span className="text-[11px] text-muted-foreground">
            {state.settings.provider === "claude-cli" ? "Haiku · Claude Code" : "Luna · Codex"}
          </span>
          <Button
            size="icon-sm"
            type="submit"
            disabled={!question.trim() || !meeting || asking}
            aria-label="Send question"
          >
            {asking ? <LoaderCircle className="animate-spin" /> : <ArrowRight />}
          </Button>
        </div>
      </form>
    </aside>
  )
}
