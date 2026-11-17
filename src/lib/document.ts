import type { Meeting, ReadableDocument, Segment } from "@/lib/types"

export function transcriptFingerprint(segments: Segment[]): string {
  return segments.map((segment) => `${segment.id}:${segment.revision}`).join("|")
}
export function removeFillers(text: string): string {
  return text
    .replace(/\b(?:u+m+|u+h+|e+r+m+|e+h+m+|e+m+m+|h+m+m+)\b[\s,]*/gi, " ")
    .replace(/[ \t]+/g, " ")
    .replace(/\s+([,.!?;:])/g, "$1")
    .replace(/^[\s,;]+/, "")
    .trim()
}
export function manualCoveredSegmentIDs(document: ReadableDocument): Set<string> {
  return new Set(
    document.author === "user"
      ? document.sourceFingerprint.split("|").flatMap((entry) => {
          const colon = entry.lastIndexOf(":")
          return colon > 0 && /^\d+$/.test(entry.slice(colon + 1)) ? [entry.slice(0, colon)] : []
        })
      : []
  )
}

export type SpeakerRun = Segment & { presentationID: string }

function intactRun(segment: Segment): SpeakerRun {
  return { ...segment, presentationID: JSON.stringify([segment.id, "whole"]) }
}

export function isNoteSegment(segment: Segment): boolean {
  return (
    segment.kind === "note" ||
    (segment.kind == null &&
      segment.start === segment.end &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(segment.id))
  )
}

// Match native TranscriptDocument.speakerRuns. These are presentation copies:
// canonical IDs, recognition wording and source-clock timing remain untouched.
export function speakerRuns(segment: Segment, raw = false): SpeakerRun[] {
  const text = raw ? segment.rawText : segment.text
  const words = segment.captionWords
  if (
    segment.status === "manual" ||
    isNoteSegment(segment) ||
    !words?.length ||
    words.map((word) => word.text).join(" ") !== text
  )
    return [intactRun(segment)]
  const runs: SpeakerRun[] = []
  for (const [index, word] of words.entries()) {
    const speaker = word.speaker ?? segment.speaker
    const last = runs.at(-1)
    if (last?.speaker === speaker) {
      last.text += ` ${word.text}`
      last.rawText += ` ${word.text}`
      last.end = Math.max(last.end, word.end)
    } else {
      runs.push({
        ...segment,
        start: word.start,
        end: word.end,
        speaker,
        rawText: word.text,
        text: word.text,
        captionWords: undefined,
        presentationID: JSON.stringify([segment.id, "word", index]),
      })
    }
  }
  return runs
}

export function documentSpeakers(meeting: Pick<Meeting, "document" | "segments">): Set<string> {
  return new Set(
    [
      ...meeting.segments
        .flatMap((segment) => [...speakerRuns(segment), ...speakerRuns(segment, true)])
        .map((run) => run.speaker),
      ...(meeting.document?.blocks?.map((block) => block.speaker) ?? []),
    ].filter(Boolean)
  )
}

export type DocumentParagraph = {
  id: string
  text: string
  segments: SpeakerRun[]
  speaker?: string
  needsReview?: boolean
}

export function documentParagraphs(
  meeting: Pick<Meeting, "document" | "segments" | "speakerNames">,
  raw: boolean
): DocumentParagraph[] {
  const current = meeting.document
  const prefix = current?.sourceFingerprint ? current.sourceFingerprint.split("|") : []
  const coveredIDs = current ? manualCoveredSegmentIDs(current) : new Set<string>()
  const documentMatches =
    current &&
    (current.author === "user" ||
      prefix.every(
        (value, index) =>
          value === `${meeting.segments[index]?.id}:${meeting.segments[index]?.revision}`
      ))
  const paragraphs: DocumentParagraph[] = []
  const byID = new Map(meeting.segments.map((segment) => [segment.id, segment]))
  let start = 0
  if (!raw && documentMatches) {
    if (
      current.blocks?.length &&
      (current.author !== "user" ||
        current.blocks.map((block) => block.text).join("\n\n") === current.text)
    ) {
      paragraphs.push(
        ...current.blocks
          .filter((block) => block.text.trim())
          .map((block, index) => ({
            id: JSON.stringify(["block", block.id, index]),
            text: block.text,
            speaker: block.speaker,
            needsReview: block.needsReview,
            segments: block.sourceIDs.flatMap((id) => {
              const segment = byID.get(id)
              return segment ? [intactRun(segment)] : []
            }),
          }))
      )
    } else
      paragraphs.push(
        ...current.text
          .split(/\n\s*\n/)
          .filter(Boolean)
          .map((text, index) => ({
            id: JSON.stringify(["document", index]),
            text,
            segments: [] as SpeakerRun[],
          }))
      )
    start = current.author === "user" ? 0 : prefix.length
  }
  for (const segment of meeting.segments.slice(start).flatMap((value) => speakerRuns(value, raw))) {
    if (!raw && coveredIDs.has(segment.id)) continue
    const text = raw
      ? segment.rawText.trim()
      : replaceParticipantNames(removeFillers(segment.text), participantNameReplacements(meeting))
    if (!text) continue
    const last = paragraphs.at(-1)
    const previous = last?.segments.at(-1)
    const separate =
      !last ||
      !previous ||
      segment.speaker !== previous.speaker ||
      segment.start - previous.end > 8 ||
      (last.text.length > 650 && /[.!?]$/.test(last.text))
    if (separate)
      paragraphs.push({
        id: segment.presentationID,
        text,
        segments: [segment],
        speaker: segment.speaker,
      })
    else {
      last.text += ` ${text}`
      last.segments.push(segment)
    }
  }
  return paragraphs
}
export function documentText(
  meeting: Pick<Meeting, "document" | "segments" | "speakerNames">,
  raw = false,
  paragraphs = documentParagraphs(meeting, raw)
): string {
  const speakers = documentSpeakers(meeting)
  const labelSpeakers =
    speakers.size > 1 || [...speakers].some((speaker) => meeting.speakerNames?.[speaker]?.trim())
  return paragraphs
    .map((paragraph) => {
      const speaker =
        paragraph.speaker &&
        (meeting.speakerNames?.[paragraph.speaker] ??
          paragraph.speaker.replace(/^(?:Imported audio|Microphone|System audio) · /, ""))
      return speaker && labelSpeakers
        ? `${speaker}:
${paragraph.text}`
        : paragraph.text
    })
    .join("\n\n")
}

export function participantNameReplacements(
  meeting: Pick<Meeting, "document" | "segments" | "speakerNames">,
  previousNames: Record<string, string> = {}
): Map<string, string> {
  const replacements = new Map<string, string>()
  for (const speaker of documentSpeakers(meeting)) {
    const original = speaker.replace(/^(?:Imported audio|Microphone|System audio) · /, "")
    const previous = previousNames[speaker] ?? original
    const current = meeting.speakerNames?.[speaker] ?? original
    if (
      previous !== current &&
      previous &&
      !previous.includes(" + ") &&
      !/^(?:you|speaker\s*\d+|unknown(?: speaker)?|mixed speakers|microphone|system audio|note)$/i.test(
        previous
      )
    )
      replacements.set(previous, current)
  }
  return replacements
}
export function replaceParticipantNames(text: string, replacements: Map<string, string>): string {
  if (!replacements.size) return text
  const alternatives = [...replacements.keys()]
    .sort((a, b) => b.length - a.length)
    .map((name) => name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .join("|")
  const pattern = new RegExp(`(?<![\\p{L}\\p{N}_])(?:${alternatives})(?![\\p{L}\\p{N}_])`, "gu")
  return text.replace(pattern, (name) => replacements.get(name) ?? name)
}
export function refreshSpeakerNames(meeting: Meeting): void {
  const document = meeting.document
  if (
    !document ||
    (!Object.keys(meeting.speakerNames ?? {}).length &&
      !Object.keys(document.speakerNames ?? {}).length)
  )
    return
  if (JSON.stringify(document.speakerNames) === JSON.stringify(meeting.speakerNames ?? {})) return
  const replacements = participantNameReplacements(meeting, document.speakerNames)
  const text = replaceParticipantNames(document.text, replacements)
  const blocks = document.blocks?.map((block) => ({
    ...block,
    text: replaceParticipantNames(block.text, replacements),
  }))
  const changed =
    text !== document.text ||
    blocks?.some((block, index) => block.text !== document.blocks?.[index].text)
  if (changed) meeting.documentHistory = [...(meeting.documentHistory ?? []), document]
  meeting.document = {
    ...document,
    text,
    blocks,
    speakerNames: { ...meeting.speakerNames },
    ...(changed
      ? {
          revision:
            Math.max(
              document.revision,
              ...(meeting.documentHistory ?? []).map((value) => value.revision)
            ) + 1,
          createdAt: new Date().toISOString(),
        }
      : {}),
  }
}
