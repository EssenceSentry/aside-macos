import AVFoundation
import AppKit
import AsideAudio
import UniformTypeIdentifiers

@MainActor
final class AppController {
  let store: LocalStore
  private var allMeetings: [Meeting]
  private var selectedID: String?
  private var documents: [IndexedDocument]
  private var glossary: [GlossaryEntry]
  private let voiceLibrary: VoiceProfileStore
  private let narration: LocalNarrationService
  private var narrationTask: Task<NarrationResult, Error>?
  private var narrationSetupTask: Task<Void, Error>?
  private var voiceProfiles: [VoiceProfile]
  private var settings: Settings
  private var runtime = RuntimeState()
  private let capture: any CaptureService
  private let captureDeliveries = DispatchGroup()
  private var unsavedCaptureTracks: [AudioTrack] = []
  private var requiredCaptureFailure: String?
  private var stoppingCapture: Task<Void, Never>?
  private var scheduledWork: Task<Void, Never>?
  private var liveModels: Task<Void, Never>?
  private let transcription: any SpeechService
  private let intelligence: MeetingIntelligence
  private let speakerReview: any SpeakerReviewing
  private let providerAvailabilityOverride: Bool?
  private var recordingGeneration: String?
  private var recordingID: String?
  private var recordingStarted: Date?
  private var recordingBase: Double = 0
  private var ticker: Task<Void, Never>?
  private enum AudioWork {
    case chunk(String, CapturedChunk, generation: String?)
    case finish(String, generation: String)
    var meetingID: String {
      switch self {
      case .chunk(let id, _, _), .finish(let id, _): return id
      }
    }
    var trackID: String? {
      if case .chunk(_, let chunk, _) = self { return chunk.track.id }
      return nil
    }
  }
  private struct CaptionKey: Hashable {
    let meetingID: String
    let generation: String
    let source: String
  }
  private enum CaptionMode {
    case streaming(String, any LiveCaptionSession)
    case fresh
    case deferred
  }
  private var captions: [CaptionKey: CaptionMode] = [:]
  private var pending: [AudioWork] = []
  private var transcriptionTask: Task<Void, Never>?
  private var transcribing: Bool { transcriptionTask != nil }
  private var inFlightTracks: Set<String> = []
  private var assistantBusy = false
  private var questionTask: Task<ChatMessage, Error>?
  private var recognitionOperation: String?
  private var finalRequested: Set<String> = []
  private var shuttingDown = false
  private var lastRepair = Date.distantPast
  private var lastAnticipation = Date.distantPast
  private var lastRepairFingerprint = ""
  private var lastAnticipationFingerprint = ""
  private var players: [AVAudioPlayer] = []
  var onState: ((AppState) -> Void)?
  var onRecordingTick: ((String, Double, RuntimeState) -> Void)?
  init(
    storage: LocalStore? = nil, speech: (any SpeechService)? = nil,
    assistant: MeetingIntelligence? = nil, providerAvailable: Bool? = nil,
    capture: (any CaptureService)? = nil, speakerReview: (any SpeakerReviewing)? = nil
  ) throws {
    store = try storage ?? LocalStore()
    voiceLibrary = VoiceProfileStore(root: store.root)
    narration = LocalNarrationService(root: store.root)
    voiceProfiles = (try? voiceLibrary.profiles()) ?? []
    allMeetings = try store.meetings()
    documents = try store.indexedDocuments()
    glossary = try store.loadGlossary()
    settings = try store.loadSettings()
    selectedID = allMeetings.first?.id
    self.capture = capture ?? AudioCapture()
    self.speakerReview = speakerReview ?? SpeakerReviewService(root: store.root)
    transcription = speech ?? TranscriptionEngine(root: store.root)
    intelligence = assistant ?? MeetingIntelligence()
    providerAvailabilityOverride = providerAvailable
    runtime.providerAvailable =
      providerAvailable ?? MeetingIntelligence.available(provider: settings.provider)
    runtime.finalProviderAvailable =
      providerAvailable ?? MeetingIntelligence.available(provider: settings.finalWriter)
    runtime.assistantStatus = settings.assistantEnabled ? "Ready" : "Assistant off"
    recoverTracks()
    Task {
      let narrationStatus = await narration.status()
      runtime.narrationModelStatus = narrationStatus.ready ? "ready" : "notDownloaded"
      runtime.narrationMessage = narrationStatus.message
      runtime.speakerModelStatus =
        await transcription.speakersDownloaded() ? "ready" : "notDownloaded"
      runtime.voiceReferenceReady = FileManager.default.fileExists(
        atPath: store.root.appendingPathComponent("voice-profile/reference.wav").path)
      runtime.finalModelStatus = await transcription.finalDownloaded() ? "ready" : "notDownloaded"
      runtime.modelStatus = await transcription.downloaded() ? "ready" : "notDownloaded"
      if runtime.modelStatus == "ready" {
        runtime.modelMessage = "Parakeet TDT v3 · local multilingual recognition"
      }
      publish()
    }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self else { return }
        self.tick()
      }
    }
  }
  var state: AppState {
    let meeting = allMeetings.first { $0.id == selectedID }
    let directory = meeting.map { store.root.appendingPathComponent("meetings/" + $0.id) }
    return AppState(
      meetings: allMeetings.map(\.summary), meeting: meeting,
      documents: documents.map(\.record), glossary: glossary, settings: settings, runtime: runtime,
      audioExports: meeting.flatMap { value in
        directory.map { RecordingExport.sources(meeting: value, directory: $0) }
      } ?? [], voiceProfiles: voiceProfiles)
  }
  func setContextFloating(_ floating: Bool) {
    runtime.contextFloating = floating
    publish()
  }
  private func publish() { onState?(state) }
  private func setError(_ message: String) {
    runtime.lastError = message
    publish()
  }
  private func update(_ id: String, _ change: (inout Meeting) throws -> Void) throws {
    guard let index = allMeetings.firstIndex(where: { $0.id == id }) else {
      throw AsideError("Meeting not found")
    }
    var next = allMeetings[index]
    try change(&next)
    TranscriptDocument.refreshSpeakerNames(&next)
    next.applySuggestedTitle()
    next.updatedAt = timestamp()
    try store.save(next)
    allMeetings[index] = next
  }
  private func selected() throws -> Meeting {
    guard let meeting = state.meeting else { throw AsideError("Create or select a meeting first") }
    return meeting
  }
  private func recoverTracks() {
    for meeting in allMeetings {
      do {
        let dir = try store.meetingDirectory(meeting.id)
        let files = try FileManager.default.contentsOfDirectory(
          at: dir, includingPropertiesForKeys: nil)
        for url in files
        where ["caf", "wav", "m4a", "mp3", "aiff", "flac"].contains(url.pathExtension.lowercased())
          && !meeting.audioTracks.contains(where: { $0.filename == url.lastPathComponent })
        {
          let audio = try AVAudioFile(forReading: url)
          let duration = Double(audio.length) / audio.processingFormat.sampleRate
          let label =
            url.lastPathComponent.hasPrefix("mic-")
            ? "Microphone"
            : url.lastPathComponent.hasPrefix("system-") ? "System audio" : "Imported audio"
          let track = AudioTrack(
            id: url.deletingPathExtension().lastPathComponent, label: label,
            filename: url.lastPathComponent, duration: duration)
          try update(meeting.id) { value in
            value.audioTracks.append(track)
            value.duration = max(value.duration, ChunkWriter.offset(for: track.filename) + duration)
          }
        }
      } catch {
        runtime.lastError =
          "Some saved audio needs attention: \(error.localizedDescription). Existing files have been retained."
      }
    }
  }
  func handle(action: String, payload p: [String: Any]) async throws -> AppState? {
    defer {
      Task {
        runtime.totalCalls = await intelligence.totalCalls
        publish()
      }
    }
    switch action {
    case "getState": break
    case "setAssistantView":
      guard let view = p["view"] as? String, ["ready", "ask"].contains(view) else {
        throw AsideError("Choose a contextual help view")
      }
      runtime.assistantView = view
    case "createMeeting":
      guard recordingID == nil else {
        throw AsideError("Stop recording before creating another meeting")
      }
      var meeting = Meeting.make(
        title: clean(p["title"] as? String, fallback: "Untitled meeting"),
        context: p["context"] as? String ?? "",
        language: language(p["language"] as? String ?? settings.language))
      meeting.titleIsAutomatic =
        (p["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      meeting.startIncomplete = p["startIncomplete"] as? Bool
      try store.save(meeting)
      allMeetings.insert(meeting, at: 0)
      selectedID = meeting.id
      runtime.assistantView = "ready"
    case "selectMeeting":
      guard recordingID == nil else { throw AsideError("Stop recording before switching meetings") }
      guard let id = p["id"] as? String, allMeetings.contains(where: { $0.id == id }) else {
        throw AsideError("Meeting not found")
      }
      if selectedID != id { runtime.assistantView = "ready" }
      selectedID = id
    case "renameMeeting":
      guard let id = p["id"] as? String, allMeetings.contains(where: { $0.id == id }),
        let title = p["title"] as? String,
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw AsideError("Enter a meeting name") }
      try update(id) { value in
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.titleIsAutomatic = false
        retirePredictions(&value)
      }
    case "renameSpeaker":
      guard let id = p["meetingID"] as? String,
        let meeting = allMeetings.first(where: { $0.id == id })
      else { throw AsideError("Meeting not found") }
      guard let speaker = p["speaker"] as? String else { throw AsideError("Choose a speaker") }
      let known = TranscriptDocument.speakers(meeting.segments).union(
        meeting.document?.blocks?.map(\.speaker) ?? [])
      let name = (p["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard known.contains(speaker), name.count <= 80 else {
        throw AsideError("Choose a current speaker and a name of up to 80 characters")
      }
      try update(meeting.id) { value in
        var names = value.speakerNames ?? [:]
        if name.isEmpty { names.removeValue(forKey: speaker) } else { names[speaker] = name }
        value.speakerNames = names
      }
    case "deleteMeeting":
      guard let id = p["id"] as? String,
        let index = allMeetings.firstIndex(where: { $0.id == id })
      else { throw AsideError("Meeting not found") }
      guard recordingID == nil, stoppingCapture == nil, !transcribing,
        recognitionOperation == nil, narrationTask == nil, questionTask == nil,
        !captions.keys.contains(where: { $0.meetingID == id })
      else { throw AsideError("Finish recording or processing before deleting this meeting") }
      try requireAssistantIdle()
      try store.trashMeeting(id)
      pending.removeAll { $0.meetingID == id }
      finalRequested.remove(id)
      allMeetings.remove(at: index)
      if selectedID == id {
        selectedID = allMeetings.isEmpty ? nil : allMeetings[min(index, allMeetings.count - 1)].id
        runtime.assistantView = "ready"
      }
      runtime.lastError = nil
    case "updateMeeting":
      let meeting = try selected()
      try update(meeting.id) { value in
        if let title = p["title"] as? String {
          let updated = clean(title, fallback: "Untitled meeting")
          if updated != value.title { value.titleIsAutomatic = false }
          value.title = updated
        }
        if let context = p["context"] as? String { value.context = context }
        if let flag = p["startIncomplete"] as? Bool { value.startIncomplete = flag }
        if let names = p["speakerNames"] as? [String: String] {
          let known = TranscriptDocument.speakers(value.segments).union(
            value.document?.blocks?.map(\.speaker) ?? [])
          value.speakerNames = names.filter {
            known.contains($0.key)
              && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && $0.value.count <= 80
          }
        }
        if let lang = p["language"] as? String { value.language = language(lang) }
        if let ids = p["documentIDs"] as? [String] {
          value.documentIDs = ids.filter { id in documents.contains { $0.record.id == id } }
        }
        if value.title != meeting.title || value.context != meeting.context
          || value.language != meeting.language || value.startIncomplete != meeting.startIncomplete
          || Set(value.documentIDs) != Set(meeting.documentIDs)
        {
          retirePredictions(&value)
        }
      }
    case "startRecording": try await startRecording()
    case "stopRecording": await stopRecording()
    case "downloadModel":
      guard runtime.modelStatus != "downloading" else { break }
      runtime.modelStatus = "downloading"
      runtime.modelMessage = "Downloading Parakeet TDT v3. This can take several minutes."
      publish()
      do {
        try await transcription.prepare(download: true)
        runtime.modelStatus = "ready"
        runtime.modelMessage = "Parakeet TDT v3 · local multilingual recognition"
        if selectedID != nil { try queueSavedAudio() }
      } catch {
        runtime.modelStatus = "error"
        runtime.modelMessage = error.localizedDescription
        throw error
      }
    case "downloadSpeakerModel":
      runtime.speakerModelStatus = "downloading"
      publish()
      do {
        try await transcription.prepareSpeakers(download: true)
        try await transcription.prepareCoverage(download: true)
        runtime.speakerModelStatus = "ready"
      } catch {
        runtime.speakerModelStatus = "error"
        throw error
      }
    case "identifySavedSpeakers":
      try await identifySavedSpeakers()
    case "importVoiceReference":
      try await importVoiceReference()
    case "downloadFinalModel":
      guard runtime.finalModelStatus != "downloading" else { break }
      runtime.finalModelStatus = "downloading"
      publish()
      do {
        try await transcription.prepareFinal(download: true)
        try await transcription.prepareCoverage(download: true)
        runtime.finalModelStatus = "ready"
      } catch {
        runtime.finalModelStatus = "error"
        throw error
      }
    case "copyText":
      guard let text = p["text"] as? String, text.count <= 1_000_000 else {
        throw AsideError("No transcript text to copy")
      }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      return nil
    case "editDocument":
      let meeting = try selected()
      let text = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text.count <= 1_000_000 else {
        throw AsideError("Enter transcript text first")
      }
      guard p["baseFingerprint"] as? String == transcriptFingerprint(meeting.segments) else {
        throw AsideError("The transcript changed while you were editing. Your draft has been kept.")
      }
      guard (p["revision"] as? Int ?? 0) == (meeting.document?.revision ?? 0) else {
        throw AsideError("The document changed; reopen it before saving")
      }
      try update(meeting.id) { value in
        if let old = value.document {
          value.documentHistory = (value.documentHistory ?? []) + [old]
        }
        value.document = ReadableDocument(
          speakerNames: value.speakerNames, text: text,
          sourceFingerprint: transcriptFingerprint(value.segments),
          revision: TranscriptDocument.nextRevision(value), createdAt: timestamp(), author: "user")
      }
    case "resumeProcessing":
      let meeting = try selected()
      guard meeting.pendingStage != nil else { break }
      if meeting.pendingStage == .polish, !meeting.segments.isEmpty {
        try await runAssistant(repair: true, anticipate: false, meetingID: meeting.id)
      } else {
        try await reprocessAudio()
      }
    case "reprocessAudio": try await reprocessAudio()
    case "importAudio": try await importAudio()
    case "retranscribe":
      guard runtime.modelStatus == "ready" else {
        throw AsideError("Download Parakeet TDT v3 first")
      }
      try queueSavedAudio()
    case "addPassage":
      let meeting = try selected()
      let text = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw AsideError("Enter a passage first") }
      let segment = Segment(
        id: newID(), start: meeting.duration, end: meeting.duration,
        speaker: p["speaker"] as? String ?? "Note", rawText: text, text: text, status: "manual",
        revision: 0, corrections: [], kind: "note")
      try update(meeting.id) { $0.segments.append(segment) }
    case "editSegment", "revertSegment":
      let meeting = try selected()
      guard let id = p["id"] as? String, let revision = p["revision"] as? Int else {
        throw AsideError("Missing segment revision")
      }
      try update(meeting.id) { value in
        guard let i = value.segments.firstIndex(where: { $0.id == id }) else {
          throw AsideError("Segment not found")
        }
        guard value.segments[i].revision == revision else {
          throw AsideError("This passage changed. Review the latest text before saving.")
        }
        let text =
          action == "revertSegment" ? value.segments[i].rawText : p["text"] as? String ?? ""
        value.segments[i].corrections.append(
          Correction(
            id: newID(), before: value.segments[i].text, after: text,
            reason: action == "revertSegment"
              ? "Restored raw transcription by user" : "Manual edit", createdAt: timestamp(),
            beforeRevision: revision, afterRevision: revision + 1))
        value.segments[i].text = text
        value.segments[i].status = "manual"
        value.segments[i].revision += 1
      }
    case "learnCorrection":
      let meeting = try selected()
      guard let id = p["segmentID"] as? String, let revision = p["revision"] as? Int,
        let segment = meeting.segments.first(where: { $0.id == id }), segment.revision == revision,
        segment.status == "manual"
      else { throw AsideError("Confirm the current manual correction before learning vocabulary") }
      let term = clean(p["term"] as? String, fallback: "")
      let alias = clean(p["alias"] as? String, fallback: "")
      guard !term.isEmpty, !alias.isEmpty, term.caseInsensitiveCompare(alias) != .orderedSame,
        segment.text.range(of: term, options: .caseInsensitive) != nil,
        ([segment.rawText] + segment.corrections.map(\.before)).contains(where: {
          $0.range(of: alias, options: .caseInsensitive) != nil
        })
      else {
        throw AsideError(
          "The term must occur in corrected text and its alias in the original passage")
      }
      let terms = Set([term.lowercased(), alias.lowercased()])
      guard
        !glossary.contains(where: {
          !Set(([$0.term] + $0.aliases).map { $0.lowercased() }).isDisjoint(with: terms)
        })
      else {
        throw AsideError(
          "This vocabulary overlaps an existing entry; the existing definition was kept")
      }
      glossary.append(
        GlossaryEntry(
          id: newID(), term: term, aliases: [alias], definition: p["definition"] as? String ?? "",
          source: "Confirmed correction · \(meeting.title) · \(timestamp())"))
      try store.saveGlossary(glossary)
    case "addDocuments": try await addDocuments()
    case "removeDocument":
      guard let id = p["id"] as? String else { throw AsideError("Missing document ID") }
      let meeting = try selected()
      try update(meeting.id) {
        $0.documentIDs.removeAll { $0 == id }
        retirePredictions(&$0)
      }
    case "addGlossary":
      let term = clean(p["term"] as? String, fallback: "")
      guard !term.isEmpty else { throw AsideError("Enter a term") }
      glossary.append(
        GlossaryEntry(
          id: newID(), term: term, aliases: p["aliases"] as? [String] ?? [],
          definition: p["definition"] as? String ?? "", source: "Manual"))
      try store.saveGlossary(glossary)
    case "removeGlossary":
      glossary.removeAll { $0.id == p["id"] as? String }
      try store.saveGlossary(glossary)
    case "extractGlossary":
      let meeting = try selected()
      try requireAssistantIdle()
      assistantBusy = true
      defer { assistantBusy = false }
      runtime.assistantStatus = "Extracting glossary"
      publish()
      let additions = try await intelligence.extractGlossary(
        meeting: meeting, documents: meetingDocuments(meeting), glossary: glossary,
        settings: settings)
      guard contextMatches(meeting) else {
        throw AsideError("Meeting context changed; glossary proposals were not applied")
      }
      for entry in additions
      where !glossary.contains(where: { existing in
        let old = Set(([existing.term] + existing.aliases).map { $0.lowercased() })
        let new = Set(([entry.term] + entry.aliases).map { $0.lowercased() })
        return !old.isDisjoint(with: new)
      }) { glossary.append(entry) }
      try store.saveGlossary(glossary)
      runtime.assistantStatus = "Glossary updated"
    case "importVoiceProfile":
      guard recordingID == nil else {
        throw AsideError("Finish recording before importing a voice reference")
      }
      try requireAssistantIdle()
      let name = clean(p["name"] as? String, fallback: "")
      guard !name.isEmpty else { throw AsideError("Enter the person's name first") }
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.audio]
      guard panel.runModal() == .OK, let input = panel.url else { break }
      let samples = try await Task.detached { try AsideAudio.AudioPreparationModel.load(input) }
        .value
      try voiceLibrary.save(samples, name: name)
      voiceProfiles = try voiceLibrary.profiles()
    case "saveVoiceProfile":
      guard recordingID == nil, !transcribing else {
        throw AsideError("Finish recording and voice identification before saving a voice")
      }
      try requireAssistantIdle()
      let meeting = try selected()
      guard let speaker = p["speaker"] as? String else { throw AsideError("Choose a speaker") }
      let name = clean(p["name"] as? String, fallback: "")
      guard !name.isEmpty else { throw AsideError("Enter the person's name first") }
      let directory = try store.meetingDirectory(meeting.id)
      assistantBusy = true
      runtime.assistantStatus = "Saving voice reference"
      publish()
      defer {
        assistantBusy = false
        runtime.assistantStatus = "Ready"
      }
      let samples = try await Task.detached {
        try VoiceProfileAudio.sample(meeting: meeting, speaker: speaker, directory: directory)
      }.value
      let profile = try voiceLibrary.save(
        samples, name: name, meetingID: meeting.id, speaker: speaker)
      voiceProfiles = try voiceLibrary.profiles()
      try update(meeting.id) { value in
        var names = value.speakerNames ?? [:]
        names[speaker] = profile.name
        value.speakerNames = names
      }
    case "renameVoiceProfile":
      guard let id = p["id"] as? String, let name = p["name"] as? String else {
        throw AsideError("Choose a voice profile and enter its name")
      }
      try voiceLibrary.rename(id, name: name)
      voiceProfiles = try voiceLibrary.profiles()
    case "setVoiceProfileEnabled":
      guard let id = p["id"] as? String, let enabled = p["enabled"] as? Bool else {
        throw AsideError("Choose a voice profile")
      }
      try voiceLibrary.setEnabled(id, enabled: enabled)
      voiceProfiles = try voiceLibrary.profiles()
    case "playVoiceProfile":
      guard let id = p["id"] as? String else { throw AsideError("Choose a voice profile") }
      let player = try AVAudioPlayer(contentsOf: voiceLibrary.sampleURL(id))
      players.removeAll { !$0.isPlaying }
      players.append(player)
      player.play()
    case "updateSettings":
      if let flag = p["contextualCaptions"] as? Bool {
        guard recordingID == nil || flag == (settings.contextualCaptions ?? true) else {
          throw AsideError("Stop recording before changing live caption mode.")
        }
        settings.contextualCaptions = flag
      }
      if let text = p["workContext"] as? String {
        guard text.count <= 16_000 else {
          throw AsideError("Keep the shared work brief under 16,000 characters")
        }
        try store.saveWorkContext(text)
        settings.workContext = text
      }
      if let provider = p["provider"] as? String, ["claude-cli", "codex-cli"].contains(provider) {
        settings.provider = provider
      }
      if let provider = p["finalProvider"] as? String,
        ["codex-terra", "claude-cli", "codex-cli"].contains(provider)
      {
        settings.finalProvider = provider
      }
      if let flag = p["assistantEnabled"] as? Bool { settings.assistantEnabled = flag }
      if let flag = p["captureSystemAudio"] as? Bool { settings.captureSystemAudio = flag }
      if let flag = p["shortenAudioPauses"] as? Bool { settings.shortenAudioPauses = flag }
      if let flag = p["reduceAudioFillers"] as? Bool { settings.reduceAudioFillers = flag }
      if let flag = p["identifySpeakers"] as? Bool { settings.identifySpeakers = flag }
      if let value = p["repairInterval"] as? Double {
        settings.repairInterval = min(600, max(15, value))
      }
      if let value = p["anticipationInterval"] as? Double {
        settings.anticipationInterval = min(600, max(20, value))
      }
      if let value = p["language"] as? String { settings.language = language(value) }
      runtime.providerAvailable =
        providerAvailabilityOverride ?? MeetingIntelligence.available(provider: settings.provider)
      runtime.finalProviderAvailable =
        providerAvailabilityOverride
        ?? MeetingIntelligence.available(provider: settings.finalWriter)
      runtime.assistantStatus = settings.assistantEnabled ? "Ready" : "Assistant off"
      try store.saveSettings(settings)
    case "regenerateMemory":
      try requireAssistantIdle()
      guard recordingID == nil, !transcribing else {
        throw AsideError("Finish recording and transcription before regenerating memory")
      }
      let previous = settings.workContext
      let memorySettings = settings
      assistantBusy = true
      defer { assistantBusy = false }
      runtime.lastError = nil
      runtime.assistantStatus = "Reading memories"
      publish()
      let corpus = try await Task.detached(priority: .utility) { try MemoryReader.collect() }.value
      let text: String
      do {
        text = try await intelligence.regenerateMemory(corpus: corpus, settings: memorySettings) {
          [weak self] step, total in
          await self?.memoryProgress(step: step, total: total)
        }
      } catch let draft as MemoryDraftError {
        // Preserve the failed synthesis privately for diagnosis without replacing
        // the user's working brief or repeating all memory ingestion to inspect it.
        let directory = store.root.appendingPathComponent("work-context-drafts")
        try? FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? store.write(
          ["draft": draft.text, "sourceNotes": draft.sourceNotes.joined(separator: "\n\n")],
          to: directory.appendingPathComponent(newID() + ".json"))
        throw draft
      }
      guard settings.workContext == previous else {
        throw AsideError(
          "Your work context changed during regeneration. The new summary was not applied.")
      }
      try store.write(
        corpus.manifest, to: store.root.appendingPathComponent("work-context-sources.json"))
      try store.saveWorkContext(text)
      settings.workContext = text
      try store.saveSettings(settings)
      runtime.assistantStatus = "Ready"
    case "runAssistant":
      try await runAssistant(
        repair: p["repair"] as? Bool ?? true, anticipate: p["anticipate"] as? Bool ?? true)
    case "ask":
      let meeting = try selected()
      let question = clean(p["question"] as? String, fallback: "")
      guard !question.isEmpty else { throw AsideError("Enter a question") }
      guard questionTask == nil else { throw AsideError("Your question is already being answered") }
      try update(meeting.id) {
        $0.messages.append(
          ChatMessage(
            id: newID(), role: "user", text: question, sources: [], createdAt: timestamp()))
      }
      let questionDocuments = meetingDocuments(meeting)
      let questionGlossary = glossary
      let questionSettings = settings
      let task = Task { [intelligence] in
        try await intelligence.ask(
          question: question, meeting: meeting, documents: questionDocuments,
          glossary: questionGlossary, settings: questionSettings)
      }
      questionTask = task
      runtime.assistantView = "ask"
      runtime.answering = true
      publish()
      defer {
        questionTask = nil
        runtime.answering = false
        publish()
      }
      let answer = try await task.value
      try Task.checkCancellation()
      guard !shuttingDown else { throw CancellationError() }
      // New captions, refined voice labels and automatic written paragraphs
      // can arrive during an answer. Keep the answer to its saved question and
      // versioned source locators rather than discarding useful text.
      guard let current = allMeetings.first(where: { $0.id == meeting.id }),
        current.context == meeting.context,
        Set(current.documentIDs) == Set(meeting.documentIDs)
      else {
        throw AsideError("Meeting context changed; ask again using the current documents")
      }
      try update(meeting.id) { $0.messages.append(answer) }
    case "dismissCard":
      let meeting = try selected()
      try update(meeting.id) { value in
        if let i = value.cards.firstIndex(where: { $0.id == p["id"] as? String }) {
          value.cards[i].dismissed = true
        }
      }
    case "openSource":
      if let id = p["documentID"] as? String, RecentSessionReader.isSourceID(id) {
        guard let url = RecentSessionReader.sourceURL(id: id) else {
          throw AsideError("Archived session is unavailable")
        }
        NSWorkspace.shared.open(url)
        return nil
      }
      guard let id = p["documentID"] as? String, documents.contains(where: { $0.record.id == id }),
        let url = try store.documentURL(id)
      else { throw AsideError("Source document is unavailable") }
      NSWorkspace.shared.open(url)
      return nil
    case "playSegment":
      try playSegment(p["id"] as? String)
      return nil
    case "stopPlayback":
      for player in players { player.stop() }
      players = []
      return nil
    case "exportAudio":
      try await exportAudio(
        prepared: p["prepared"] as? Bool ?? false, source: p["source"] as? String)
      return nil
    case "prepareNarration":
      try await prepareNarration()
    case "exportNarration":
      try await exportNarration(
        voiceProfileID: p["voiceProfileID"] as? String ?? "you",
        language: p["language"] as? String ?? "English")
      return nil
    case "cancelNarration":
      narrationTask?.cancel()
      narrationSetupTask?.cancel()
      runtime.narrationMessage = "Cancelling narration"
    case "exportMeeting":
      try exportMeeting(format: p["format"] as? String ?? "markdown")
      return nil
    case "revealData":
      NSWorkspace.shared.open(store.root)
      return nil
    case "clearError": runtime.lastError = nil
    default: throw AsideError("Unknown action: \(action)")
    }
    publish()
    return state
  }
  private func recognitionProgress(_ message: String, operation: String) {
    guard recognitionOperation == operation else { return }
    runtime.assistantStatus = message
    publish()
  }
  private func importVoiceReference() async throws {
    guard recordingID == nil else {
      throw AsideError("Finish recording before learning your voice")
    }
    try requireAssistantIdle()
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    guard panel.runModal() == .OK, let input = panel.url else { return }
    let samples = try await Task.detached { try AsideAudio.AudioPreparationModel.load(input) }.value
    guard (16000 * 8...16000 * 120).contains(samples.count) else {
      throw AsideError(
        "Choose 8–120 seconds containing only your voice. The previous sample was kept.")
    }
    let folder = store.root.appendingPathComponent("voice-profile")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = folder.appendingPathComponent("reference.wav")
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.copyItem(
        at: file, to: folder.appendingPathComponent("reference-" + newID() + ".wav"))
    }
    let temporary = folder.appendingPathComponent(newID() + ".wav")
    try AsideAudio.AudioPreparationModel.write(samples, to: temporary)
    if FileManager.default.fileExists(atPath: file.path) {
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: file)
    }
    runtime.voiceReferenceReady = true
  }
  private func polishProgress(step: Int, total: Int) {
    runtime.assistantStatus = "Polishing passage \(step) of \(total)"
    publish()
  }
  private func memoryProgress(step: Int, total: Int) {
    runtime.assistantStatus = "Consolidating memory \(step) of \(total)"
    publish()
  }
  private func retirePredictions(_ meeting: inout Meeting) {
    for index in meeting.cards.indices where !meeting.cards[index].dismissed {
      meeting.cards[index].dismissed = true
      meeting.cards[index].superseded = true
    }
  }
  private func contextMatches(_ original: Meeting) -> Bool {
    guard let current = allMeetings.first(where: { $0.id == original.id }),
      current.title == original.title,
      current.context == original.context, current.language == original.language,
      current.startIncomplete == original.startIncomplete,
      current.speakerNames == original.speakerNames,
      current.document?.revision == original.document?.revision,
      current.document?.text == original.document?.text,
      Set(current.documentIDs) == Set(original.documentIDs)
    else { return false }
    return Self.transcriptSnapshotMatches(original.segments, current: current.segments)
  }

  nonisolated static func transcriptSnapshotMatches(_ original: [Segment], current: [Segment])
    -> Bool
  {
    let byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    // Vocabulary extraction can use any earlier word or voice attribution.
    // New speech is allowed; every supplied source observation stays intact.
    return original.allSatisfy { byID[$0.id] == $0 }
  }
  private func clean(_ value: String?, fallback: String) -> String {
    let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return text.isEmpty ? fallback : text
  }
  private func language(_ value: String) -> String {
    ["en", "es"].contains(value) ? value : "auto"
  }
  private func meetingDocuments(_ meeting: Meeting) -> [IndexedDocument] {
    documents.filter { meeting.documentIDs.contains($0.record.id) }
  }
  private func requireAssistantIdle() throws {
    guard !assistantBusy else { throw AsideError("The assistant is already working") }
  }
  private func warmLiveModels() {
    guard liveModels == nil, settings.assistantEnabled, !assistantBusy, !transcribing,
      narrationTask == nil, narrationSetupTask == nil
    else { return }
    let speech = transcription
    liveModels = Task { [weak self] in
      defer { self?.liveModels = nil }
      if await speech.downloaded() {
        guard !Task.isCancelled else { return }
        try? await speech.prepare(download: false)
      }
      if await speech.speakersDownloaded() {
        guard !Task.isCancelled else { return }
        try? await speech.prepareSpeakers(download: false)
      }
      if await speech.finalDownloaded() {
        guard !Task.isCancelled else { return }
        try? await speech.prepareFinal(download: false)
      }
    }
  }
  private func voiceReference() -> URL? {
    let url = store.root.appendingPathComponent("voice-profile/reference.wav")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
  private func liveAudioChunks(_ meeting: Meeting) -> [CapturedChunk] {
    let end =
      meeting.audioTracks.map { ChunkWriter.offset(for: $0.filename) + $0.duration }.max() ?? 0
    let directory = store.root.appendingPathComponent("meetings/" + meeting.id)
    return meeting.audioTracks.compactMap { track in
      let offset = ChunkWriter.offset(for: track.filename)
      guard !track.filename.hasPrefix("import-"), offset + track.duration > end - 60 else {
        return nil
      }
      return CapturedChunk(
        track: track, url: directory.appendingPathComponent(track.filename),
        offset: offset, speaker: track.label)
    }
  }
  private func runAssistant(
    repair: Bool, anticipate: Bool, meetingID: String? = nil, compose: Bool = true
  ) async throws {
    try requireAssistantIdle()
    let meeting: Meeting
    if let meetingID {
      guard let found = allMeetings.first(where: { $0.id == meetingID }) else {
        throw AsideError("Meeting not found")
      }
      meeting = found
    } else {
      meeting = try selected()
    }
    let finalPass = compose && recordingID != meeting.id && meeting.status != "recording"
    let durablePolish = finalPass && repair
    if durablePolish {
      try update(meeting.id) {
        $0.pendingStage = .polish
        $0.processingError = nil
        $0.status = "processing"
      }
    }
    var finished = false
    assistantBusy = true
    defer {
      assistantBusy = false
      if durablePolish && !finished {
        try? update(meeting.id) {
          $0.status = "interrupted"
          $0.processingError =
            "Document polishing did not finish. The previous transcript was kept."
        }
      }
    }
    runtime.lastError = nil
    runtime.assistantStatus = "Reviewing context"
    publish()
    if repair && !finalPass && meeting.document?.author != "user" {
      runtime.assistantStatus = "Listening to recent audio"
      publish()
      let heard = try await transcription.recognizeLiveWindow(
        liveAudioChunks(meeting), segments: meeting.segments,
        language: meeting.language == "auto" ? nil : meeting.language,
        identifySpeakers: settings.identifySpeakers ?? true,
        reference: voiceReference())
      var live = meeting
      heard.applySpeakerAssignments(to: &live.segments)
      live.recognitionAlternatives = heard.alternatives
      runtime.assistantStatus = "Writing recent speech"
      publish()
      if let document = try await intelligence.composeDocument(
        meeting: live, documents: meetingDocuments(live), glossary: glossary,
        settings: settings, live: true)
      {
        try update(meeting.id) { value in
          guard value.document?.author != "user",
            value.document?.revision == meeting.document?.revision,
            value.context == meeting.context, value.language == meeting.language,
            value.title == meeting.title, Set(value.documentIDs) == Set(meeting.documentIDs),
            document.sourceFingerprint
              == transcriptFingerprint(Array(value.segments.prefix(meeting.segments.count)))
          else { return }
          value.document = document
          value.recognitionAlternatives = heard.alternatives
          heard.applySpeakerAssignments(to: &value.segments)
          if !heard.warnings.isEmpty {
            value.recognitionNotice = heard.warnings.joined(separator: "\n")
          }
        }
      }
    }
    // Measure the forecast cadence from this request, so response latency does
    // not add another interval before the next update.
    if anticipate { lastAnticipation = Date() }
    let result = try await intelligence.run(
      meeting: allMeetings.first { $0.id == meeting.id } ?? meeting,
      documents: meetingDocuments(meeting), glossary: glossary,
      settings: settings, repair: false, anticipate: anticipate)
    try update(meeting.id) { value in
      let allowRepairs = value.document?.author != "user"
      _ = result.apply(to: &value, allowRepairs: allowRepairs)
    }
    if finalPass && repair, let current = allMeetings.first(where: { $0.id == meeting.id }),
      current.document?.author != "user"
    {
      runtime.assistantStatus = "Polishing transcript"
      publish()
      do {
        if let document = try await intelligence.composeDocument(
          meeting: current, documents: meetingDocuments(current), glossary: glossary,
          settings: settings,
          progress: { [weak self] step, total in
            await self?.polishProgress(step: step, total: total)
          })
        {
          try update(meeting.id) { value in
            if value.document?.author == "user" { return }
            guard transcriptFingerprint(value.segments) == document.sourceFingerprint,
              value.context == current.context, value.language == current.language,
              value.startIncomplete == current.startIncomplete,
              Set(value.documentIDs) == Set(current.documentIDs)
            else {
              throw AsideError(
                "The transcript or meeting context changed during polishing. Resume processing to use the current version."
              )
            }
            if let old = value.document {
              value.documentHistory = (value.documentHistory ?? []) + [old]
            }
            value.document = document
          }
        }
      } catch let failure as DocumentPolishError {
        let folder = try store.meetingDirectory(meeting.id).appendingPathComponent(
          "document-drafts")
        try? FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? store.write(failure.draft, to: folder.appendingPathComponent(newID() + ".json"))
        throw failure
      }
    }
    finished = true
    if durablePolish {
      try update(meeting.id) {
        $0.pendingStage = nil
        $0.processingError = nil
        $0.status = "complete"
      }
    }
    runtime.assistantStatus = "Ready"
    if repair && finalPass { lastRepair = Date() }
  }
  /// The voice-review operation already owns assistantBusy. Reuse its single
  /// writer call instead of re-entering runAssistant's idle/ownership boundary.
  private func refreshSpeakerReviewProse(meetingID: String, warnings: [String]) async throws {
    guard let reviewed = allMeetings.first(where: { $0.id == meetingID }),
      let previous = reviewed.document, previous.author != "user",
      (previous.blocks ?? []).isEmpty
        || (previous.blocks ?? []).contains(where: { $0.sourceIDs.isEmpty })
    else { return }
    guard settings.assistantEnabled, runtime.finalProviderAvailable == true else {
      try update(meetingID) {
        $0.speakerNotice =
          ($0.speakerNotice ?? "")
          + " Written text was kept; its unmapped paragraph labels retain the earlier attribution because automatic rewriting is unavailable."
      }
      return
    }
    runtime.assistantStatus = "Writing conversation with updated voices"
    publish()
    // This is a saved-audio operation, even if an interrupted meeting still has
    // an old recording status. Do not route it to the live writer configuration.
    var input = reviewed
    input.status = "ready"
    do {
      guard
        let document = try await intelligence.composeDocument(
          meeting: input, documents: meetingDocuments(input), glossary: glossary,
          settings: settings, live: false)
      else { return }
      guard contextMatches(reviewed) else { return }
      try update(meetingID) { value in
        guard value.document == previous,
          document.sourceFingerprint
            == transcriptFingerprint(Array(value.segments.prefix(reviewed.segments.count)))
        else { return }
        value.documentHistory = (value.documentHistory ?? []) + [previous]
        value.document = document
        value.speakerNotice =
          ([
            "Voice labels and the written conversation were updated from the latest measured voices."
          ] + warnings).joined(separator: " ")
      }
    } catch {
      if error is CancellationError || Task.isCancelled { throw error }
      guard contextMatches(reviewed) else { return }
      try update(meetingID) {
        $0.speakerNotice =
          ($0.speakerNotice ?? "")
          + " The automatic rewrite could not finish; the previous written text was kept."
      }
    }
  }
  private func identifySavedSpeakers() async throws {
    guard recordingID == nil, !transcribing else {
      throw AsideError("Stop recording and let transcription finish before identifying voices")
    }
    try requireAssistantIdle()
    let meeting = try selected()
    guard !meeting.audioTracks.isEmpty, meeting.segments.contains(where: { !$0.isNote }) else {
      throw AsideError("Save audio and transcribed speech before identifying voices")
    }
    let fingerprint = transcriptFingerprint(meeting.segments)
    let directory = try store.meetingDirectory(meeting.id)
    let passID = newID()
    let chunks = meeting.audioTracks.map { track in
      CapturedChunk(
        track: track, url: directory.appendingPathComponent(track.filename),
        offset: ChunkWriter.offset(for: track.filename), speaker: track.label)
    }
    let reference = store.root.appendingPathComponent("voice-profile/reference.wav")
    let operation = newID()
    assistantBusy = true
    recognitionOperation = operation
    runtime.assistantStatus = "Identifying voices"
    runtime.lastError = nil
    publish()
    defer {
      assistantBusy = false
      recognitionOperation = nil
    }
    do {
      let result = try await speakerReview.review(
        chunks: chunks, segments: meeting.segments,
        output: directory.appendingPathComponent("speaker-reviews/" + passID),
        reference: FileManager.default.fileExists(atPath: reference.path) ? reference : nil,
        progress: { [weak self] message in
          await self?.recognitionProgress(message, operation: operation)
        })
      try update(meeting.id) { value in
        guard transcriptFingerprint(value.segments) == fingerprint,
          value.audioTracks == meeting.audioTracks, value.document == meeting.document,
          value.speakerNames == meeting.speakerNames
        else {
          throw AsideError(
            "The transcript changed during voice review. Saved voice analysis was kept; retry using the current text."
          )
        }
        _ = applySpeakerReview(result, to: &value, passID: passID)
        retirePredictions(&value)
      }
      try await refreshSpeakerReviewProse(meetingID: meeting.id, warnings: result.warnings)
      runtime.assistantStatus = settings.assistantEnabled ? "Ready" : "Assistant off"
    } catch {
      runtime.assistantStatus = "Voice identification needs attention"
      throw error
    }
  }
  /// Live segment IDs end with the index within their committed audio chunk.
  /// Final recognition has independent IDs, so time overlap is conservative
  /// fallback evidence when an older meeting has no prepared-track manifest.
  private func liveTrackID(_ segment: Segment) -> String? {
    guard let colon = segment.id.lastIndex(of: ":"),
      Int(segment.id[segment.id.index(after: colon)...]) != nil
    else { return nil }
    return String(segment.id[..<colon])
  }
  private func protectedRecognitionTracks(_ meeting: Meeting) -> Set<String>? {
    let manual = meeting.segments.filter { $0.status == "manual" && !$0.isNote }
    guard !manual.isEmpty || meeting.document?.author == "user" else { return nil }
    let covered = meeting.document.map(manualCoveredSegmentIDs) ?? []
    let trackIDs = Set(meeting.audioTracks.map(\.id))
    var retained = Set(meeting.preparedRecording?.trackIDs ?? [])
    retained.formUnion(meeting.protectedPassTrackIDs ?? [])
    var unmapped: [Segment] = []
    for segment in meeting.segments where !segment.isNote {
      if let id = liveTrackID(segment), trackIDs.contains(id) {
        if covered.contains(segment.id) || segment.status == "manual" { retained.insert(id) }
      } else {
        unmapped.append(segment)
      }
    }
    for track in meeting.audioTracks where !retained.contains(track.id) {
      let start = ChunkWriter.offset(for: track.filename)
      // Filenames store millisecond offsets; an adjacent track can begin
      // within half a millisecond of the preceding passage's exact end.
      if unmapped.contains(where: {
        min($0.end, start + track.duration) - max($0.start, start) > 0.0005
      }) {
        retained.insert(track.id)
      }
    }
    // A contextual word may begin in one CAF and end in the next. Keep both
    // originals together whenever one is protected, including when a user
    // edited a different group owned by the same track.
    let byID = Dictionary(
      meeting.audioTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var links: [String: Set<String>] = [:]
    for segment in meeting.segments where !segment.isNote {
      guard let ownerID = liveTrackID(segment), let owner = byID[ownerID],
        segment.id.hasPrefix(ownerID + ":-")
      else { continue }
      for track in meeting.audioTracks where track.id != ownerID && track.label == owner.label {
        let start = ChunkWriter.offset(for: track.filename)
        if min(segment.end, start + track.duration) - max(segment.start, start) > 0.0005 {
          links[ownerID, default: []].insert(track.id)
          links[track.id, default: []].insert(ownerID)
        }
      }
    }
    var remaining = Array(retained)
    while let id = remaining.popLast() {
      for neighbor in links[id] ?? [] where retained.insert(neighbor).inserted {
        remaining.append(neighbor)
      }
    }
    return retained
  }
  private func reprocessAudio(meetingID: String? = nil, polish: Bool = true) async throws {
    guard recordingID == nil, !transcribing else {
      throw AsideError("Stop recording and let current transcription finish first")
    }
    try requireAssistantIdle()
    let meeting: Meeting
    if let meetingID {
      guard let found = allMeetings.first(where: { $0.id == meetingID }) else {
        throw AsideError("Meeting not found")
      }
      meeting = found
    } else {
      meeting = try selected()
    }
    guard !pending.contains(where: { $0.meetingID == meeting.id }) else {
      throw AsideError("Let the current transcription finish first")
    }
    guard !meeting.audioTracks.isEmpty else { throw AsideError("This meeting has no saved audio") }
    let protected = protectedRecognitionTracks(meeting)
    let tracks = meeting.audioTracks.filter { protected?.contains($0.id) != true }
    let notice =
      "Your edited transcript and its existing audio passages were kept. Final recognition only checks audio outside those protected tracks."
    guard !tracks.isEmpty else {
      try update(meeting.id) {
        $0.pendingStage = nil
        $0.processingError = nil
        $0.recognitionNotice = notice
        $0.status = "ready"
      }
      publish()
      return
    }
    let trackIDs = Set(tracks.map(\.id))
    let fingerprint = transcriptFingerprint(meeting.segments)
    let directory = try store.meetingDirectory(meeting.id)
    let passID = newID()
    let base = protected == nil ? 0 : tracks.map { ChunkWriter.offset(for: $0.filename) }.min() ?? 0
    let chunks = tracks.map { track in
      CapturedChunk(
        track: track, url: directory.appendingPathComponent(track.filename),
        offset: ChunkWriter.offset(for: track.filename) - base, speaker: track.label)
    }
    assistantBusy = true
    runtime.assistantStatus = "Preparing audio"
    runtime.lastError = nil
    try update(meeting.id) {
      $0.status = "processing"
      $0.pendingStage = .recognition
      $0.processingError = nil
    }
    publish()
    do {
      // Startup and offline recognition share these local models. Let the
      // existing warmup finish before starting another heavy Core ML load.
      if let warming = liveModels {
        runtime.assistantStatus = "Preparing speech models"
        publish()
        await warming.value
        try Task.checkCancellation()
      }
      let operation = newID()
      recognitionOperation = operation
      defer { recognitionOperation = nil }
      let voice = store.root.appendingPathComponent("voice-profile/reference.wav")
      let final = try await transcription.reprocess(
        chunks, output: directory.appendingPathComponent("derived/" + passID),
        reduceFillers: settings.reduceAudioFillers ?? false,
        shortenPauses: settings.shortenAudioPauses,
        language: meeting.language == "auto" ? nil : meeting.language,
        terms: glossary.filter { entry in
          entry.sourceDocumentID.map { meeting.documentIDs.contains($0) } ?? true
        }.map(\.term), identifySpeakers: settings.identifySpeakers ?? true,
        reference: FileManager.default.fileExists(atPath: voice.path) ? voice : nil,
        progress: { [weak self] message in
          await self?.recognitionProgress(message, operation: operation)
        })
      recognitionOperation = nil
      let segments = final.segments.map { original in
        var segment = original
        segment.start += base
        segment.end += base
        // Anonymous labels are local to this pass. Never apply the name of
        // an earlier, independently clustered speaker to the new speech.
        if protected != nil && segment.speaker.contains(" · ") {
          segment.speaker += " (pass " + String((meeting.recognitionHistory?.count ?? 0) + 1) + ")"
        }
        return segment
      }
      // Coverage drives acoustic recovery and diagnostics, not permission to
      // write. The language agent needs the available noisy readings even when
      // their timestamps do not account for every detected speech interval.
      var recognitionWarnings = final.warnings
      if !final.coverageVerified {
        recognitionWarnings.append(
          "Acoustic coverage is uncertain; available recognition was kept.")
      } else if !final.coverageComplete {
        recognitionWarnings.append(
          "Some detected speech may be missing from this recognition pass.")
      }
      let keptSegments = meeting.segments.filter { segment in
        if segment.isNote { return true }
        guard protected != nil else { return false }
        return !trackIDs.contains(liveTrackID(segment) ?? "")
      }
      guard !segments.isEmpty || (protected != nil && keptSegments.count == meeting.segments.count)
      else {
        throw AsideError(
          "The new recognition pass returned no speech; the existing transcript was kept")
      }
      try update(meeting.id) { value in
        guard transcriptFingerprint(value.segments) == fingerprint,
          value.document == meeting.document, value.audioTracks == meeting.audioTracks
        else {
          throw AsideError("The transcript changed; the new recognition was not applied")
        }
        value.recognitionHistory =
          (value.recognitionHistory ?? []) + [
            RecognitionSnapshot(
              id: passID,
              createdAt: timestamp(),
              technique:
                "Prior recognition before final re-feeding; final model: \(runtime.finalModelStatus == "ready" ? "Whisper Turbo" : "Parakeet v3"); shorten pauses: \(settings.shortenAudioPauses ?? (runtime.finalModelStatus != "ready")); filler masking: \(settings.reduceAudioFillers ?? false)",
              segments: value.segments, speakerNames: value.speakerNames,
              alternatives: value.recognitionAlternatives)
          ]
        if protected != nil {
          value.protectedPassTrackIDs = Set(value.protectedPassTrackIDs ?? []).union(trackIDs)
            .sorted()
          value.recognitionNotice = ([notice] + recognitionWarnings).joined(separator: " ")
          value.pendingStage = nil
          value.status = "ready"
        } else {
          if let old = value.document {
            value.documentHistory = (value.documentHistory ?? []) + [old]
          }
          value.preparedRecording = PreparedRecording(
            passID: passID, trackIDs: tracks.map(\.id), timelineOffset: base)
          value.document = nil
          let keptSpeakers = TranscriptDocument.speakers(keptSegments)
          value.speakerNames = value.speakerNames?.filter { key, _ in
            key == "You" || keptSpeakers.contains(key)
          }
          value.recognitionNotice =
            recognitionWarnings.isEmpty ? nil : recognitionWarnings.joined(separator: " ")
          value.speakerNotice = nil
          value.protectedPassTrackIDs = nil
          value.pendingStage = settings.assistantEnabled ? .polish : nil
          value.status = value.pendingStage == nil ? "complete" : "processing"
        }
        let keptIDs = Set(keptSegments.map(\.id))
        let retainedAlternatives = (value.recognitionAlternatives ?? []).filter {
          !keptIDs.isDisjoint(with: $0.sourceIDs)
        }
        value.recognitionAlternatives =
          retainedAlternatives
          + final.alternatives.map { original in
            var alternative = original
            alternative.start += base
            alternative.end += base
            alternative.words = original.words.map { original in
              var word = original
              word.start += base
              word.end += base
              return word
            }
            return alternative
          }
        value.segments = (segments + keptSegments).sorted { $0.start < $1.start }
        value.recognitionDraft = nil
        retirePredictions(&value)
      }
      var warnings = recognitionWarnings
      do {
        try store.write(
          transcriptionLedger(meeting.id).union(trackIDs),
          to: directory.appendingPathComponent("transcribed.json"))
        try changeCaptionTracks(meeting.id) { $0.subtract(trackIDs) }
      } catch {
        // The accepted track IDs are already durable in the meeting itself.
        warnings.append(
          "Could not refresh the live transcription index: " + error.localizedDescription)
      }
      assistantBusy = false
      runtime.assistantStatus = "Ready"
      publish()
      await releaseIdleAcoustics()
      if protected == nil && polish && settings.assistantEnabled {
        try await runAssistant(repair: true, anticipate: false, meetingID: meeting.id)
      }
      let persistenceWarnings = warnings.dropFirst(recognitionWarnings.count)
      if !persistenceWarnings.isEmpty { setError(persistenceWarnings.joined(separator: ". ")) }
    } catch {
      assistantBusy = false
      try? update(meeting.id) {
        $0.status = "interrupted"
        $0.processingError = error.localizedDescription
      }
      await releaseIdleAcoustics()
      throw error
    }
  }

  private func startRecording() async throws {
    guard recordingID == nil else { return }
    runtime.lastError = nil
    let meeting = try selected()
    guard meeting.status != "processing" else {
      throw AsideError("Let final recognition finish before recording more audio")
    }
    // Imported or interrupted recordings remain independent timeline tracks.
    recordingBase = meeting.duration
    let dir = try store.meetingDirectory(meeting.id)
    try update(meeting.id) {
      $0.status = "recording"
      $0.pendingStage = .recognition
    }
    let generation = newID()
    let captionGeneration = (settings.contextualCaptions ?? true) ? generation : nil
    let deliveries = captureDeliveries
    let captureMeetingID = meeting.id
    unsavedCaptureTracks = []
    requiredCaptureFailure = nil
    runtime.captureHealth = [CaptureSource.microphone.rawValue: "active"]
    if settings.captureSystemAudio {
      runtime.captureHealth?[CaptureSource.systemAudio.rawValue] = "active"
    }
    recordingGeneration = generation
    recordingID = meeting.id
    recordingStarted = Date()
    runtime.recording = true
    publish()
    warmLiveModels()
    do {
      try await capture.start(
        directory: dir, systemAudio: settings.captureSystemAudio, timelineOffset: recordingBase,
        onChunk: { [weak self] chunk in
          deliveries.enter()
          Task { @MainActor in
            defer { deliveries.leave() }
            self?.receive(chunk, meetingID: captureMeetingID, generation: captionGeneration)
          }
        },
        onLevel: { [weak self] level, system in
          Task { @MainActor in
            guard let self, self.recordingGeneration == generation else { return }
            let source: CaptureSource = system ? .systemAudio : .microphone
            guard self.runtime.captureHealth?[source.rawValue] != "failed" else { return }
            if system { self.runtime.systemLevel = level } else { self.runtime.inputLevel = level }
          }
        }, onError: { [weak self] message in Task { @MainActor in self?.setError(message) } },
        onIssue: { [weak self] issue in
          deliveries.enter()
          Task { @MainActor in
            let stop = self?.captureIssue(issue, meetingID: captureMeetingID) == true
            // Stop waits for all delivered issues, including this one.
            deliveries.leave()
            if stop { await self?.stopRecording() }
          }
        })
    } catch {
      guard recordingGeneration == generation else { return }
      requiredCaptureFailure = error.localizedDescription
      await stopRecording()
      throw error
    }
  }
  private func captureIssue(_ issue: CaptureIssue, meetingID: String) -> Bool {
    guard recordingID == meetingID else { return false }
    let key = issue.source.rawValue
    if issue.isFailure {
      runtime.captureHealth?[key] = "failed"
      if issue.source == .microphone {
        requiredCaptureFailure = issue.message
        runtime.inputLevel = 0
      } else {
        runtime.systemLevel = 0
      }
    } else if runtime.captureHealth?[key] != "failed" {
      runtime.captureHealth?[key] = "warning"
    }
    do {
      try update(meetingID) { value in
        value.captureIssues = (value.captureIssues ?? []) + [issue]
        if requiredCaptureFailure != nil {
          value.processingError = requiredCaptureFailure
          value.pendingStage = .recognition
        }
      }
      setError(issue.message)
    } catch { setError(error.localizedDescription) }
    return issue.source == .microphone && issue.isFailure
  }

  func stopRecording() async {
    if let stoppingCapture {
      await stoppingCapture.value
      return
    }
    guard let id = recordingID, let generation = recordingGeneration else { return }
    recordingGeneration = nil
    let task = Task { @MainActor in
      defer { stoppingCapture = nil }
      await capture.stop()
      // Producers have closed their files. Wait until every committed-track
      // callback and source issue has actually reached the controller.
      await withCheckedContinuation { continuation in
        captureDeliveries.notify(queue: .main) { continuation.resume() }
      }
      let duration = recordingBase + (recordingStarted.map { Date().timeIntervalSince($0) } ?? 0)
      let interrupted = shuttingDown || requiredCaptureFailure != nil
      recordingID = nil
      recordingStarted = nil
      runtime.recording = false
      runtime.inputLevel = 0
      runtime.systemLevel = 0
      runtime.captureHealth = runtime.captureHealth?.mapValues {
        $0 == "failed" ? "failed" : "stopped"
      }
      do {
        try update(id) { meeting in
          for track in unsavedCaptureTracks
          where !meeting.audioTracks.contains(where: { $0.id == track.id }) {
            meeting.audioTracks.append(track)
            meeting.duration = max(
              meeting.duration, ChunkWriter.offset(for: track.filename) + track.duration)
          }
          meeting.duration = max(meeting.duration, duration)
          meeting.pendingStage = .recognition
          meeting.status = interrupted ? "interrupted" : "processing"
          meeting.processingError = requiredCaptureFailure
        }
        if !interrupted { finalRequested.insert(id) }
      } catch { setError(error.localizedDescription) }
      pending.append(.finish(id, generation: generation))
      drainTranscription()
      publish()
    }
    stoppingCapture = task
    await task.value
  }

  private func receive(_ original: CapturedChunk, meetingID: String, generation: String?) {
    do {
      let chunk = original
      try update(meetingID) { meeting in
        if !meeting.audioTracks.contains(where: { $0.id == chunk.track.id }) {
          meeting.audioTracks.append(chunk.track)
        }
        meeting.duration = max(meeting.duration, chunk.offset + chunk.track.duration)
      }
      if runtime.modelStatus == "ready" && (!shuttingDown || generation != nil) {
        pending.append(.chunk(meetingID, chunk, generation: generation))
        drainTranscription()
      }
      publish()
    } catch {
      unsavedCaptureTracks.append(original.track)
      setError(
        "Audio remains on disk, but the meeting update failed: \(error.localizedDescription)")
    }
  }
  private func queueSavedAudio() throws {
    let meeting = try selected()
    let dir = try store.meetingDirectory(meeting.id)
    let done = try pendingCaptionTracks(meeting.id).union(transcriptionLedger(meeting.id))
      .union(meeting.preparedRecording?.trackIDs ?? [])
      .union(protectedRecognitionTracks(meeting) ?? [])
    for track in meeting.audioTracks
    where !done.contains(track.id) && !pending.contains(where: { $0.trackID == track.id })
      && !inFlightTracks.contains(track.id)
    {
      pending.append(
        .chunk(
          meeting.id,
          CapturedChunk(
            track: track, url: dir.appendingPathComponent(track.filename),
            offset: ChunkWriter.offset(for: track.filename), speaker: track.label), generation: nil
        ))
    }
    drainTranscription()
  }
  private func transcriptionLedger(_ id: String) -> Set<String> {
    guard let path = try? store.meetingDirectory(id).appendingPathComponent("transcribed.json")
    else { return [] }
    return (try? store.read(Set<String>.self, from: path)) ?? []
  }
  // Set before feeding a contextual stream. A crash or failed decoder can
  // leave stable captions for some of a track; only final ASR can replace them.
  private func pendingCaptionTracks(_ id: String) throws -> Set<String> {
    let file = try store.meetingDirectory(id).appendingPathComponent("caption-pending.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try store.read(Set<String>.self, from: file)
  }
  private func changeCaptionTracks(_ id: String, _ change: (inout Set<String>) -> Void) throws {
    var tracks = try pendingCaptionTracks(id)
    let old = tracks
    change(&tracks)
    if old != tracks {
      try store.write(
        tracks, to: store.meetingDirectory(id).appendingPathComponent("caption-pending.json"))
    }
  }
  private func storeSegments(_ segments: [Segment], meetingID: String) throws {
    guard let current = allMeetings.first(where: { $0.id == meetingID }) else {
      throw AsideError("Meeting no longer exists.")
    }
    var known = Set(current.segments.map(\.id))
    let additions = segments.filter { known.insert($0.id).inserted }
    guard !additions.isEmpty else { return }
    try update(meetingID) { meeting in
      meeting.segments.append(contentsOf: additions)
      meeting.segments.sort { $0.start < $1.start }
    }
    publish()
  }
  private func applyCaption(_ snapshot: LiveCaptionSnapshot, key: CaptionKey) throws {
    guard case .streaming(let token, _) = captions[key],
      token == snapshot.generation, snapshot.source == key.source
    else { throw CancellationError() }
    try storeSegments(snapshot.stableSegments, meetingID: key.meetingID)
    if snapshot.isTerminal {
      try acknowledgeTracks(snapshot.trackIDs, meetingID: key.meetingID)
      try changeCaptionTracks(key.meetingID) { $0.subtract(snapshot.trackIDs) }
    }
  }
  private func acknowledgeTracks(_ ids: [String], meetingID: String) throws {
    try store.write(
      transcriptionLedger(meetingID).union(ids),
      to: store.meetingDirectory(meetingID).appendingPathComponent("transcribed.json"))
  }
  private func openCaption(_ key: CaptionKey) async throws -> (any LiveCaptionSession)? {
    let token = newID()
    let session = try await transcription.makeLiveCaptionSession(
      source: key.source, generation: token
    ) {
      [weak self] snapshot in
      guard let self else { throw CancellationError() }
      try await self.applyCaption(snapshot, key: key)
    }
    if let session { captions[key] = .streaming(token, session) }
    return session
  }
  private func deferCaption(_ key: CaptionKey, error: Error) async {
    let old = captions.updateValue(.deferred, forKey: key)
    if case .streaming(_, let session) = old { await session.cancel() }
    let message =
      "Live captions for " + key.source
      + " paused. Saved audio will be checked during final recognition. "
      + error.localizedDescription
    setError(message)
  }
  private func handleCaption(_ chunk: CapturedChunk, key: CaptionKey) async throws -> Bool {
    if case .fresh = captions[key] { return false }
    // Reserve even a failed stream's later chunks to prevent per-chunk replay.
    try changeCaptionTracks(key.meetingID) { $0.insert(chunk.track.id) }
    if case .deferred = captions[key] { return true }
    do {
      let session: any LiveCaptionSession
      if case .streaming(_, let current) = captions[key] {
        session = current
      } else if let new = try await openCaption(key) {
        session = new
      } else {
        try changeCaptionTracks(key.meetingID) { $0.remove(chunk.track.id) }
        captions[key] = .fresh
        return false
      }
      do { try await session.append(chunk) } catch is CaptionDiscontinuity {
        // The previous clock must be retired before a new decoder owns this source.
        _ = try await session.finish()
        captions.removeValue(forKey: key)
        guard let next = try await openCaption(key) else {
          throw AsideError("Could not restart this source's caption decoder.")
        }
        try await next.append(chunk)
      }
    } catch { await deferCaption(key, error: error) }
    return true
  }
  private func finishCaptions(meetingID: String, generation: String) async {
    let keys = captions.keys.filter { $0.meetingID == meetingID && $0.generation == generation }
    for key in keys {
      if case .streaming(_, let session) = captions[key] {
        do { _ = try await session.finish() } catch { await deferCaption(key, error: error) }
      }
      captions.removeValue(forKey: key)
    }
  }
  private func drainTranscription() {
    guard !transcribing, !pending.isEmpty else { return }
    transcriptionTask = Task {
      defer { transcriptionTask = nil }
      while !pending.isEmpty {
        let work = pending.removeFirst()
        switch work {
        case .finish(let id, let generation):
          await finishCaptions(meetingID: id, generation: generation)
        case .chunk(let id, let chunk, let generation):
          inFlightTracks.insert(chunk.track.id)
          defer { inFlightTracks.remove(chunk.track.id) }
          do {
            if let generation,
              try await handleCaption(
                chunk,
                key: CaptionKey(
                  meetingID: id, generation: generation, source: chunk.speaker))
            {
              continue
            }
            try storeSegments(try await transcription.transcribe(chunk), meetingID: id)
            try acknowledgeTracks([chunk.track.id], meetingID: id)
          } catch { setError("Audio saved. Transcription failed: " + error.localizedDescription) }
          if recordingID != id && !pending.contains(where: { $0.meetingID == id }) {
            try? update(id) { meeting in
              if meeting.pendingStage == nil && meeting.status != "interrupted" {
                meeting.status = finalRequested.contains(id) ? "processing" : "complete"
              }
            }
          }
          publish()
        }
      }
    }
  }
  func tick() {
    guard !shuttingDown else { return }
    guard let id = recordingID else {
      if !finalRequested.isEmpty && scheduledWork == nil && !assistantBusy && !transcribing {
        scheduledWork = Task { [weak self] in
          guard let self else { return }
          defer { scheduledWork = nil }
          await finishPendingMeetings()
        }
      }
      return
    }
    guard let index = allMeetings.firstIndex(where: { $0.id == id }) else { return }
    let elapsed = recordingBase + (recordingStarted.map { Date().timeIntervalSince($0) } ?? 0)
    allMeetings[index].duration = max(allMeetings[index].duration, elapsed)
    // Chunk commits and stop persist the timeline. A meter frame does not
    // rewrite the complete meeting or its document and recognition histories.
    if let onRecordingTick {
      onRecordingTick(id, allMeetings[index].duration, runtime)
    } else {
      publish()
    }
    let meeting = allMeetings[index]
    guard stoppingCapture == nil, scheduledWork == nil, settings.assistantEnabled,
      runtime.providerAvailable, !assistantBusy, !meeting.segments.isEmpty
    else { return }
    let revisions = transcriptFingerprint(meeting.segments)
    let glossaryData = (try? JSONEncoder().encode(glossary)).map { $0.base64EncodedString() } ?? ""
    let fingerprint =
      "\(meeting.id)|\(meeting.title)|\(meeting.context)|\(meeting.documentIDs.joined())|\(settings.provider)|\(glossaryData)|\(revisions)"
    let repair =
      fingerprint != lastRepairFingerprint
      && Date().timeIntervalSince(lastRepair) >= settings.repairInterval
    let anticipate =
      fingerprint != lastAnticipationFingerprint
      && Date().timeIntervalSince(lastAnticipation) >= settings.anticipationInterval
    guard repair || anticipate else { return }
    scheduledWork = Task { [weak self] in
      guard let self else { return }
      defer { scheduledWork = nil }
      guard !shuttingDown, !Task.isCancelled, recordingID == id, stoppingCapture == nil,
        settings.assistantEnabled, runtime.providerAvailable, !assistantBusy
      else { return }
      if repair {
        lastRepair = Date()
        lastRepairFingerprint = fingerprint
      }
      if anticipate {
        lastAnticipation = Date()
        lastAnticipationFingerprint = fingerprint
      }
      do {
        try await runAssistant(
          repair: repair, anticipate: anticipate, meetingID: id, compose: false)
      } catch {
        guard !Task.isCancelled else { return }
        runtime.assistantStatus = "Needs attention"
        setError(error.localizedDescription)
      }
      runtime.totalCalls = await intelligence.totalCalls
    }
  }

  private func finishPendingMeetings() async {
    guard !shuttingDown, !Task.isCancelled, recordingID == nil, !assistantBusy, !transcribing,
      let meeting = allMeetings.first(where: { finalRequested.contains($0.id) }),
      !pending.contains(where: { $0.meetingID == meeting.id })
    else { return }
    let id = meeting.id
    do {
      if meeting.pendingStage == .recognition {
        guard !meeting.audioTracks.isEmpty else {
          throw AsideError("No recorded audio was recovered.")
        }
        try await reprocessAudio(meetingID: id, polish: false)
      }
      // Another meeting may have begun while final recognition ran. Its live
      // work gets priority; this meeting's remaining stage is already durable.
      guard recordingID == nil, !shuttingDown, !Task.isCancelled else { return }
      if let current = allMeetings.first(where: { $0.id == id }), current.pendingStage == .polish {
        guard settings.assistantEnabled, runtime.finalProviderAvailable == true else {
          throw AsideError(
            "The recording is transcribed. Enable the assistant and make the selected final writer available to finish the document."
          )
        }
        try await runAssistant(repair: true, anticipate: false, meetingID: id)
        runtime.totalCalls = await intelligence.totalCalls
      }
      finalRequested.remove(id)
      publish()
    } catch {
      // Stop automatic retries; the persisted stage is resumed explicitly.
      // Leave the queue entry intact if even the failure could not be saved.
      do {
        try update(id) { value in
          value.status = "interrupted"
          value.processingError = error.localizedDescription
        }
        finalRequested.remove(id)
      } catch {
        setError(error.localizedDescription)
        return
      }
      runtime.assistantStatus = "Needs attention"
      setError(error.localizedDescription)
    }
  }
  private func importAudio() async throws {
    guard recordingID == nil, !transcribing else {
      throw AsideError("Finish current recording and transcription before importing audio")
    }
    try requireAssistantIdle()
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let source = panel.url else { return }
    try await importAudio(from: source)
  }
  func importAudio(from source: URL) async throws {
    guard recordingID == nil, !transcribing else {
      throw AsideError("Finish current recording and transcription before importing audio")
    }
    try requireAssistantIdle()
    let meeting = try selected()
    let dir = try store.meetingDirectory(meeting.id)
    let filename = String(
      format: "import-%012.3f-%@.%@", meeting.duration, newID(), source.pathExtension.lowercased())
    let destination = dir.appendingPathComponent(filename)
    try FileManager.default.copyItem(at: source, to: destination)
    let file = try AVAudioFile(forReading: destination)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    let track = AudioTrack(
      id: destination.deletingPathExtension().lastPathComponent, label: "Imported audio",
      filename: filename, duration: duration)
    try update(meeting.id) {
      $0.audioTracks.append(track)
      $0.duration += duration
      $0.status = "processing"
      $0.pendingStage = .recognition
      $0.processingError = nil
    }
    let finalReady = await transcription.finalDownloaded()
    let liveReady = await transcription.downloaded()
    if finalReady {
      runtime.finalModelStatus = "ready"
      try await reprocessAudio(meetingID: meeting.id)
    } else if liveReady {
      runtime.modelStatus = "ready"
      finalRequested.insert(meeting.id)
      try queueSavedAudio()
    } else {
      try update(meeting.id) { $0.status = "interrupted" }
      runtime.lastError =
        "Audio imported and saved. Download a speech model, then resume processing."
    }
  }
  private func addDocuments() async throws {
    let meeting = try selected()
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [
      UTType.plainText, UTType.pdf, UTType(filenameExtension: "md"),
      UTType(filenameExtension: "docx"),
    ].compactMap { $0 }
    guard panel.runModal() == .OK else { return }
    for source in panel.urls {
      let id = newID()
      let dir = try store.documentDirectory(id)
      let destination = dir.appendingPathComponent("source.\(source.pathExtension.lowercased())")
      try FileManager.default.copyItem(at: source, to: destination)
      let document = try DocumentIndex.extract(
        destination, id: id, displayName: source.lastPathComponent)
      try store.write(document, to: dir.appendingPathComponent("index.json"))
      documents.append(document)
      try update(meeting.id) {
        $0.documentIDs.append(id)
        retirePredictions(&$0)
      }
    }
  }
  private func playSegment(_ segmentID: String?) throws {
    let meeting = try selected()
    guard let segment = meeting.segments.first(where: { $0.id == segmentID }) else {
      throw AsideError("Passage not found")
    }
    for player in players { player.stop() }
    players = []
    let dir = try store.meetingDirectory(meeting.id)
    for track in meeting.audioTracks {
      let offset = ChunkWriter.offset(for: track.filename)
      guard segment.start >= offset - 0.1, segment.start < offset + track.duration else { continue }
      let player = try AVAudioPlayer(contentsOf: dir.appendingPathComponent(track.filename))
      player.currentTime = max(0, segment.start - offset)
      player.play()
      players.append(player)
    }
    guard !players.isEmpty else { throw AsideError("No recording is attached to this passage") }
  }
  private func exportAudio(prepared: Bool, source: String?) async throws {
    let meeting = try selected()
    guard meeting.status != "recording", meeting.status != "processing" else {
      throw AsideError("Let recording and recognition finish before exporting audio")
    }
    let directory = try store.meetingDirectory(meeting.id)
    let sources = RecordingExport.sources(meeting: meeting, directory: directory)
    guard let label = source ?? sources.first?.label,
      let selected = sources.first(where: { $0.label == label })
    else { throw AsideError("This meeting has no saved audio for that source") }
    if prepared && !selected.preparedAvailable {
      throw AsideError(
        "Improve recognition from saved audio first to create the prepared recording")
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.wav]
    panel.canCreateDirectories = true
    panel.title = prepared ? "Export prepared audio" : "Export original recording"
    panel.nameFieldStringValue =
      meeting.title.replacingOccurrences(of: "/", with: "-") + " — " + label
      + (prepared ? " prepared.wav" : " original.wav")
    guard panel.runModal() == .OK, let output = panel.url else { return }
    // Export destinations cannot replace any of the app's saved originals or derivatives.
    let resolved = output.resolvingSymlinksInPath().standardizedFileURL.path
    let workspace = store.root.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolved != workspace, !resolved.hasPrefix(workspace + "/") else {
      throw AsideError("Choose a destination outside Aside's local workspace")
    }
    try await Task.detached(priority: .userInitiated) {
      try RecordingExport.write(
        meeting: meeting, directory: directory, source: label, prepared: prepared, to: output)
    }.value
  }
  private var acousticWorkIsIdle: Bool {
    recordingID == nil && recordingGeneration == nil && stoppingCapture == nil
      && !transcribing && pending.isEmpty && captions.isEmpty
      && recognitionOperation == nil && !assistantBusy && !shuttingDown
  }

  /// Detach idle acoustic resources after offline work or before narration.
  /// Recording still warms its own models; reading saved prose needs none.
  private func releaseIdleAcoustics() async {
    guard acousticWorkIsIdle else { return }
    if let warming = liveModels {
      warming.cancel()
      await warming.value
    }
    guard acousticWorkIsIdle, !Task.isCancelled else { return }
    _ = await transcription.releaseIdleModels()
  }

  private func narrationProgress(_ message: String) {
    guard !shuttingDown else { return }
    runtime.narrationMessage = message
    publish()
  }
  private func prepareNarration() async throws {
    guard narrationSetupTask == nil, narrationTask == nil else {
      throw AsideError("Narration is already working")
    }
    runtime.narrationModelStatus = "downloading"
    runtime.narrationMessage = "Preparing local narration"
    publish()
    let task = Task { [narration] in
      try await narration.prepare(progress: { [weak self] message in
        await self?.narrationProgress(message)
      })
    }
    narrationSetupTask = task
    defer { narrationSetupTask = nil }
    do {
      try await task.value
      runtime.narrationModelStatus = "ready"
      runtime.narrationMessage = "Local narration is ready"
    } catch {
      let status = await narration.status()
      runtime.narrationModelStatus =
        status.ready ? "ready" : (error is CancellationError ? "notDownloaded" : "error")
      runtime.narrationMessage =
        error is CancellationError ? "Narration setup cancelled" : error.localizedDescription
      publish()
      if error is CancellationError { return }
      throw error
    }
  }
  private func exportNarration(voiceProfileID: String, language: String) async throws {
    guard narrationTask == nil, narrationSetupTask == nil else {
      throw AsideError("Narration is already working")
    }
    let meeting = try selected()
    let plan = try NarrationExportPlan.make(
      meeting: meeting, voiceProfileID: voiceProfileID, language: language, root: store.root)
    try FileManager.default.createDirectory(
      at: plan.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if !FileManager.default.fileExists(atPath: plan.cacheURL.path) {
      runtime.narrationMessage = "Reading the corrected transcript in the saved voice"
      publish()
      let task = Task { [narration, weak self] in
        await self?.releaseIdleAcoustics()
        try Task.checkCancellation()
        return try await narration.synthesize(
          text: plan.text, voiceSampleURL: plan.voiceURL, outputURL: plan.cacheURL,
          language: plan.language,
          progress: { [weak self] message in await self?.narrationProgress(message) })
      }
      narrationTask = task
      do {
        _ = try await task.value
        narrationTask = nil
        if recordingID != nil { warmLiveModels() }
      } catch {
        narrationTask = nil
        if recordingID != nil { warmLiveModels() }
        runtime.narrationMessage =
          error is CancellationError ? "Narration cancelled" : error.localizedDescription
        publish()
        if error is CancellationError { return }
        throw error
      }
    }
    guard !shuttingDown, !Task.isCancelled else { throw CancellationError() }
    runtime.narrationMessage = "Narration is ready to save"
    publish()
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.wav]
    panel.canCreateDirectories = true
    panel.title = "Export narrated transcript"
    panel.nameFieldStringValue =
      meeting.title.replacingOccurrences(of: "/", with: "-") + " — narrated.wav"
    guard panel.runModal() == .OK, let output = panel.url else { return }
    let resolved = output.resolvingSymlinksInPath().standardizedFileURL.path
    let workspace = store.root.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolved != workspace, !resolved.hasPrefix(workspace + "/") else {
      throw AsideError("Choose a destination outside Aside's local workspace")
    }
    let temporary = output.deletingLastPathComponent().appendingPathComponent(
      "." + newID() + ".wav")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: plan.cacheURL, to: temporary)
    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: output)
    }
    runtime.narrationMessage = "Narrated transcript saved"
    publish()
  }
  private func exportMeeting(format: String) throws {
    let meeting = try selected()
    let panel = NSSavePanel()
    let json = format == "json"
    panel.allowedContentTypes = [json ? .json : .plainText]
    panel.nameFieldStringValue =
      meeting.title.replacingOccurrences(of: "/", with: "-") + (json ? ".json" : ".md")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if json {
      try store.write(meeting, to: url)
    } else {
      let text = "# \(meeting.title)\n\n\(TranscriptDocument.plain(meeting))\n"
      try text.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }
  func reportError(_ error: Error) {
    runtime.assistantStatus = assistantBusy ? runtime.assistantStatus : "Needs attention"
    setError(error.localizedDescription)
  }
  func shutdown() async {
    shuttingDown = true
    ticker?.cancel()
    scheduledWork?.cancel()
    liveModels?.cancel()
    questionTask?.cancel()
    _ = try? await questionTask?.value
    narrationTask?.cancel()
    narrationSetupTask?.cancel()
    _ = try? await narrationTask?.value
    _ = try? await narrationSetupTask?.value
    await stopRecording()
    await transcriptionTask?.value
    for id in finalRequested {
      if let meeting = allMeetings.first(where: { $0.id == id }), meeting.pendingStage != nil {
        try? update(id) { $0.status = "interrupted" }
      }
    }
    finalRequested.removeAll()
  }
}
