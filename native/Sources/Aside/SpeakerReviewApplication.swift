import Foundation

/// Voice review changes attribution only. Every word and every audio reference stays intact.
@discardableResult
func applySpeakerReview(_ result: SpeakerReviewResult, to meeting: inout Meeting, passID: String)
  -> Int
{
  let old = meeting
  var changed = 0
  var missingWordTiming = false
  for i in meeting.segments.indices where !meeting.segments[i].isNote {
    var updated = false
    if meeting.segments[i].status != "manual",
      let original = meeting.segments[i].captionWords, !original.isEmpty,
      original.map(\.text).joined(separator: " ") == meeting.segments[i].rawText
    {
      guard let words = result.captionWordAssignments?[meeting.segments[i].id],
        original.count == words.count,
        zip(original, words).allSatisfy({
          $0.text == $1.text && $0.start == $1.start && $0.end == $1.end
        })
      else {
        missingWordTiming = true
        continue
      }
      if words != original {
        meeting.segments[i].captionWords = words
        updated = true
      }
    }
    if let label = result.labelsBySegmentID[meeting.segments[i].id], !label.isEmpty,
      label != meeting.segments[i].speaker
    {
      meeting.segments[i].speaker = label
      updated = true
    }
    if updated {
      meeting.segments[i].revision += 1
      changed += 1
    }
  }
  let foundYou = TranscriptDocument.speakers(meeting.segments.filter { !$0.isNote }).contains("You")
  let base =
    foundYou
    ? "Voice labels updated. Only me shows matches to your reference; ambiguous words remain unknown."
    : "Voice labels updated. No clear match to your reference was assigned to the recognized words."
  meeting.speakerNotice = ([base] + result.warnings).joined(separator: " ")
  if missingWordTiming {
    meeting.speakerNotice! +=
      " Some saved review results lacked matching word timing; prior measured attribution was kept."
  }
  guard changed > 0 else { return 0 }
  meeting.recognitionHistory =
    (meeting.recognitionHistory ?? []) + [
      RecognitionSnapshot(
        id: passID, createdAt: timestamp(),
        technique: "Prior voice labels; recognized wording unchanged", segments: old.segments,
        speakerNames: old.speakerNames, alternatives: old.recognitionAlternatives)
    ]
  if var document = meeting.document, document.author != "user" {
    let covered =
      document.sourceFingerprint.isEmpty
      ? 0 : document.sourceFingerprint.split(separator: "|").count
    if covered <= old.segments.count,
      document.sourceFingerprint == transcriptFingerprint(Array(old.segments.prefix(covered)))
    {
      meeting.documentHistory = (meeting.documentHistory ?? []) + [document]
      let byID = Dictionary(
        meeting.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var unmapped = document.blocks?.isEmpty ?? true
      document.blocks = document.blocks?.map { original in
        var block = original
        let sources = block.sourceIDs.compactMap { byID[$0] }
        guard !sources.isEmpty, sources.count == block.sourceIDs.count else {
          unmapped = true
          return block
        }
        let names = TranscriptDocument.speakers(sources)
        if names.count == 1 {
          block.speaker = names.first!
        } else if names.count > 1 {
          block.speaker = "Mixed speakers"
        }
        return block
      }
      document.sourceFingerprint = transcriptFingerprint(Array(meeting.segments.prefix(covered)))
      document.revision = TranscriptDocument.nextRevision(meeting)
      document.createdAt = timestamp()
      meeting.document = document
      meeting.speakerNotice! +=
        unmapped
        ? " Written text was kept. Paragraphs without saved source links retain their earlier voice labels."
        : " Written text was kept and its linked paragraph voice labels were updated."
    } else {
      meeting.speakerNotice! +=
        " The saved written document was already out of date and was kept unchanged."
    }
  }
  let known = TranscriptDocument.speakers(meeting.segments)
  meeting.speakerNames = old.speakerNames?.filter { key, _ in
    key == "You" || known.contains(key) && old.segments.contains { $0.isNote && $0.speaker == key }
  }
  return changed
}
