import AVFoundation
import Foundation
import Testing

@testable import Aside

private let fixtureSpeech = "Review the draft on Friday."

private actor TestCaptionSession: LiveCaptionSession {
  let source: String
  let generation: String
  let update: @Sendable (LiveCaptionSnapshot) async throws -> Void
  private let failAppend: Bool
  private var segments: [Segment] = []
  private var ids: [String] = []
  private var tail: Double?
  private var terminal = false
  private(set) var finishing = false
  private var pauseFinish = false
  private var release: CheckedContinuation<Void, Never>?
  init(
    source: String, generation: String, failAppend: Bool,
    update: @escaping @Sendable (LiveCaptionSnapshot) async throws -> Void
  ) {
    self.source = source
    self.generation = generation
    self.failAppend = failAppend
    self.update = update
  }
  func holdFinish() { pauseFinish = true }
  func allowFinish() {
    pauseFinish = false
    release?.resume()
    release = nil
  }
  func currentSnapshot() -> LiveCaptionSnapshot {
    LiveCaptionSnapshot(
      generation: generation, source: source, stableSegments: segments,
      trackIDs: ids, isTerminal: terminal)
  }
  func append(_ chunk: CapturedChunk) async throws {
    if let tail, abs(tail - chunk.offset) > 0.001 { throw CaptionDiscontinuity() }
    tail = chunk.offset + chunk.track.duration
    ids.append(chunk.track.id)
    let text = "Caption " + String(ids.count)
    segments.append(
      Segment(
        id: chunk.track.id + ":-1", start: chunk.offset,
        end: chunk.offset + 0.5, speaker: source, rawText: text, text: text,
        status: "raw", revision: 0, corrections: []))
    try await update(currentSnapshot())
    if failAppend { throw AsideError("Decoder failure after publication") }
  }
  func finish() async throws -> LiveCaptionSnapshot {
    finishing = true
    if pauseFinish { await withCheckedContinuation { release = $0 } }
    terminal = true
    let value = currentSnapshot()
    try await update(value)
    return value
  }
  func sendStaleUpdate() async throws { try await update(currentSnapshot()) }
  func cancel() { allowFinish() }
}

private actor LifecycleSpeech: SpeechService {
  private var hasLive = false
  private var supportsStreaming = true
  private var failStream = false
  private(set) var sessions: [TestCaptionSession] = []
  private(set) var factoryCalls = 0
  func enableLive(supportsStreaming: Bool = true, failStream: Bool = false) {
    hasLive = true
    self.supportsStreaming = supportsStreaming
    self.failStream = failStream
  }
  func makeLiveCaptionSession(
    source: String, generation: String,
    onUpdate: @escaping @Sendable (LiveCaptionSnapshot) async throws -> Void
  ) async throws -> (any LiveCaptionSession)? {
    factoryCalls += 1
    guard supportsStreaming else { return nil }
    let session = TestCaptionSession(
      source: source, generation: generation, failAppend: failStream, update: onUpdate)
    sessions.append(session)
    return session
  }
  private(set) var recognitionCalls = 0
  private(set) var retirementCalls = 0
  private(set) var finalPreparationCalls = 0
  func releaseIdleModels() async -> Bool {
    retirementCalls += 1
    return true
  }
  private(set) var liveCalls = 0
  private(set) var lastTrackIDs: [String] = []
  private var complete = true
  private var verified = true
  private var failRecognition = false
  func failNextRecognition() { failRecognition = true }
  private var holdWarmup = false
  private var warmup: CheckedContinuation<Void, Never>?
  func pauseWarmup() { holdWarmup = true }
  var isWarming: Bool { warmup != nil }
  func releaseWarmup() {
    holdWarmup = false
    warmup?.resume()
    warmup = nil
  }

  func setCoverage(_ value: Bool, verified: Bool = true) {
    complete = value
    self.verified = verified
  }
  func downloaded() async -> Bool { hasLive }
  func finalDownloaded() async -> Bool { true }
  func speakersDownloaded() async -> Bool { false }
  func prepare(download: Bool) async throws { throw AsideError("Unexpected Parakeet request") }
  func prepareFinal(download: Bool) async throws {
    finalPreparationCalls += 1
    if holdWarmup {
      await withCheckedContinuation { warmup = $0 }
      return
    }
    throw AsideError("Unexpected download")
  }
  func prepareCoverage(download: Bool) async throws { throw AsideError("Unexpected download") }
  func prepareSpeakers(download: Bool) async throws { throw AsideError("Unexpected download") }
  func transcribe(_ chunk: CapturedChunk) async throws -> [Segment] {
    liveCalls += 1
    guard hasLive else { throw AsideError("No live model installed") }
    return [
      Segment(
        id: chunk.track.id + ":0", start: chunk.offset, end: chunk.offset + 0.8,
        speaker: chunk.speaker, rawText: "Fresh", text: "Fresh", status: "raw", revision: 0,
        corrections: [])
    ]
  }
  func reprocess(
    _ chunks: [CapturedChunk], output: URL, reduceFillers: Bool, shortenPauses: Bool?,
    language: String?, terms: [String], identifySpeakers: Bool, reference: URL?,
    progress: (@Sendable (String) async -> Void)?
  ) async throws -> FinalRecognitionPass {
    recognitionCalls += 1
    lastTrackIDs = chunks.map(\.track.id)
    if failRecognition {
      failRecognition = false
      throw AsideError("Fixture recognizer is offline")
    }
    let text = complete ? fixtureSpeech : "Incomplete fragment."
    let segment = Segment(
      id: "speech-\(recognitionCalls)", start: 0, end: 0.75, speaker: "You",
      rawText: text, text: text, status: "raw", revision: 0, corrections: [])
    return FinalRecognitionPass(
      segments: [segment], warnings: complete ? [] : ["Detected speech was omitted"],
      coverageComplete: complete, coverageVerified: verified,
      alternatives: complete
        ? []
        : [
          RecognitionAlternative(
            id: "second-hearing", model: "Parakeet", sourceIDs: [segment.id], start: 0, end: 0.75,
            text: "Independent recognition of the Friday review.", words: [])
        ])
  }
}

private actor LifecycleTransport: AssistantTransport {
  private(set) var calls = 0
  private(set) var providers: [String] = []
  private(set) var prompts: [String] = []
  private var available = false
  private var pauseNext = false
  private var pauseQuestion = false
  private var questionWaiting: CheckedContinuation<Void, Never>?
  private(set) var questionCancelled = false
  func pauseQuestions() { pauseQuestion = true }
  var isQuestionWaiting: Bool { questionWaiting != nil }
  func releaseQuestion() {
    questionWaiting?.resume()
    questionWaiting = nil
  }
  private var waiting: CheckedContinuation<Void, Never>?
  func pauseNextRequest() { pauseNext = true }
  func releaseRequest() {
    waiting?.resume()
    waiting = nil
  }
  var isWaiting: Bool { waiting != nil }
  func allowRequests() { available = true }
  func response(provider: String, prompt: String) async throws -> Data {
    calls += 1
    providers.append(provider)
    prompts.append(prompt)
    if prompt.contains("Question: ") {
      if pauseQuestion {
        await withTaskCancellationHandler {
          await withCheckedContinuation { questionWaiting = $0 }
        } onCancel: {
          Task { await self.releaseQuestion() }
        }
      }
      if Task.isCancelled { questionCancelled = true }
      try Task.checkCancellation()
      guard available else { throw AsideError("Fixture assistant is offline") }
      return Data(#"{"answer":"The draft review is Friday.","sources":[]}"#.utf8)
    }
    if pauseNext {
      pauseNext = false
      await withCheckedContinuation { waiting = $0 }
    }
    // Simulate an unavailable single-pass language service until explicitly restored.
    guard available else { throw AsideError("Fixture assistant is offline") }
    return Data(
      #"{"edits":[],"cards":[],"issues":[],"blocks":[{"id":"B1","text":"Review the draft on Friday."}]}"#
        .utf8)
  }
}

@MainActor
private final class LifecycleCapture: CaptureService {
  let audio: URL
  private var sendFinalChunk: (() throws -> Void)?
  private var emit: ((Double, String) throws -> Void)?
  func send(at offset: Double, source: String = "Microphone") throws {
    try emit?(offset, source)
  }
  var report: (@Sendable (CaptureIssue) -> Void)?
  var meter: (@Sendable (Double, Bool) -> Void)?

  init(audio: URL) { self.audio = audio }

  func start(
    directory: URL, systemAudio: Bool, timelineOffset: Double,
    onChunk: @escaping @Sendable (CapturedChunk) -> Void,
    onLevel: @escaping @Sendable (Double, Bool) -> Void,
    onError: @escaping @Sendable (String) -> Void,
    onIssue: (@Sendable (CaptureIssue) -> Void)?
  ) async throws {
    var nextMic = timelineOffset
    emit = { [audio] offset, label in
      let prefix = label == "Microphone" ? "mic" : "system"
      let name = String(format: "%@-%012.3f-%@.wav", prefix, offset, newID())
      let file = directory.appendingPathComponent(name)
      try FileManager.default.copyItem(at: audio, to: file)
      let track = AudioTrack(
        id: file.deletingPathExtension().lastPathComponent, label: label,
        filename: name, duration: 1)
      onChunk(CapturedChunk(track: track, url: file, offset: offset, speaker: label))
      if label == "Microphone" { nextMic = offset + 1 }
    }
    sendFinalChunk = { [weak self] in try self?.send(at: nextMic) }
    report = onIssue
    meter = onLevel
  }

  func stop() async {
    try? sendFinalChunk?()
    emit = nil
    sendFinalChunk = nil
    report = nil
    meter = nil
  }
}

@MainActor
private func waitForLifecycle(_ description: String, _ condition: () async throws -> Bool)
  async throws
{
  let deadline = ContinuousClock.now + .seconds(4)
  while try await !condition() {
    guard ContinuousClock.now < deadline else {
      throw AsideError("Timed out waiting for " + description)
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor
private struct LifecycleFixture {
  let store: LocalStore
  let input: URL
  let speech = LifecycleSpeech()
  let transport = LifecycleTransport()
  let capture: LifecycleCapture
  let assistantEnabled: Bool

  init(directory: URL, assistantEnabled: Bool) throws {
    self.assistantEnabled = assistantEnabled
    store = try LocalStore(root: directory.appendingPathComponent("workspace"))
    var settings = Settings()
    settings.assistantEnabled = assistantEnabled
    try store.saveSettings(settings)
    input = directory.appendingPathComponent("input.wav")
    capture = LifecycleCapture(audio: input)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
    buffer.frameLength = buffer.frameCapacity
    let channel = try #require(buffer.floatChannelData?[0])
    for frame in 0..<Int(buffer.frameLength) {
      channel[frame] = 0.1 * Float(sin(2 * .pi * 250 * Double(frame) / 16_000))
    }
    let file = try AVAudioFile(forWriting: input, settings: format.settings)
    try file.write(from: buffer)
  }

  func open() async throws -> AppController {
    let controller = try AppController(
      storage: store, speech: speech,
      assistant: fixtureIntelligence(transport: transport), providerAvailable: assistantEnabled,
      capture: capture)
    let deadline = ContinuousClock.now + .seconds(4)
    while controller.state.runtime.finalModelStatus != "ready" && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(controller.state.runtime.finalModelStatus == "ready")
    let liveInstalled = await speech.downloaded()
    #expect((controller.state.runtime.modelStatus == "ready") == liveInstalled)
    return controller
  }

  func saved(_ id: String) throws -> Meeting {
    try store.read(
      Meeting.self, from: store.meetingDirectory(id).appendingPathComponent("meeting.json"))
  }

  func original(_ meeting: Meeting) throws -> Data {
    let track = try #require(meeting.audioTracks.first)
    return try Data(
      contentsOf: store.meetingDirectory(meeting.id).appendingPathComponent(track.filename))
  }
}

@MainActor
private func withLifecycle(
  assistantEnabled: Bool = false, live: Bool = false, supportsStreaming: Bool = true,
  failStream: Bool = false, slowWarmup: Bool = false,
  _ run: (LifecycleFixture, AppController) async throws -> Void
) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aside-lifecycle-" + newID())
  defer { try? FileManager.default.removeItem(at: directory) }
  let fixture = try LifecycleFixture(directory: directory, assistantEnabled: assistantEnabled)
  if live {
    await fixture.speech.enableLive(supportsStreaming: supportsStreaming, failStream: failStream)
  }
  if slowWarmup { await fixture.speech.pauseWarmup() }
  let controller = try await fixture.open()
  do {
    _ = try await controller.handle(action: "createMeeting", payload: ["title": "Reading group"])
    try await run(fixture, controller)
  } catch {
    await controller.shutdown()
    throw error
  }
  await controller.shutdown()
}

@Test @MainActor func whisperOnlyImportAndRerunPreserveTypedNotesAndOriginalAudio() async throws {
  try await withLifecycle { fixture, controller in
    try await controller.importAudio(from: fixture.input)
    let imported = try #require(controller.state.meeting)
    #expect(imported.status == "complete" && imported.pendingStage == nil)
    #expect(imported.segments.map(\.text) == [fixtureSpeech])
    #expect(imported.audioTracks.count == 1)
    #expect(try fixture.original(imported) == Data(contentsOf: fixture.input))
    _ = try await controller.handle(
      action: "addPassage", payload: ["speaker": "You", "text": "My private reminder."])
    let addedNote = controller.state.meeting?.segments.first(where: \.isNote)
    let note = try #require(addedNote)
    #expect(note.status == "manual")
    _ = try await controller.handle(
      action: "editSegment",
      payload: ["id": note.id, "revision": note.revision, "text": "My corrected reminder."])
    let editedNote = controller.state.meeting?.segments.first(where: \.isNote)
    let edited = try #require(editedNote)
    _ = try await controller.handle(action: "reprocessAudio", payload: [:])
    let result = try fixture.saved(imported.id)
    #expect(result.segments.filter(\.isNote) == [edited])
    #expect(result.segments.filter { !$0.isNote }.map(\.id) == ["speech-2"])
    let initialSpeech = try #require(imported.segments.first)
    #expect(result.recognitionHistory?.last?.segments.contains(initialSpeech) == true)
    #expect(result.audioTracks == imported.audioTracks)
    #expect(try fixture.original(result) == Data(contentsOf: fixture.input))
    #expect(await fixture.speech.recognitionCalls == 2)
    #expect(await fixture.speech.liveCalls == 0)
    #expect(await fixture.transport.calls == 0)
  }
}

@Test(arguments: [true, false])
@MainActor func incompleteRecognitionReachesFinalWriterAndKeepsEarlierVersions(_ verified: Bool)
  async throws
{
  try await withLifecycle(assistantEnabled: true) { fixture, controller in
    await fixture.transport.allowRequests()
    try await controller.importAudio(from: fixture.input)
    let earlier = try #require(controller.state.meeting)
    await fixture.speech.setCoverage(false, verified: verified)
    _ = try await controller.handle(action: "reprocessAudio", payload: [:])
    let written = try fixture.saved(earlier.id)
    #expect(written.status == "complete" && written.pendingStage == nil)
    #expect(written.processingError == nil && written.recognitionDraft == nil)
    #expect(written.segments.map(\.text) == ["Incomplete fragment."])
    #expect(written.recognitionHistory?.last?.segments == earlier.segments)
    #expect(written.documentHistory?.last == earlier.document)
    #expect(written.document?.text == fixtureSpeech)
    #expect(written.recognitionNotice?.isEmpty == false)
    let prompt = try #require(await fixture.transport.prompts.last)
    #expect(prompt.contains("Incomplete fragment."))
    #expect(prompt.contains("Independent recognition of the Friday review."))
    #expect(prompt.contains(fixtureSpeech))
    #expect(await fixture.transport.providers == ["codex-terra", "codex-terra"])
    #expect(await fixture.speech.recognitionCalls == 2)
    #expect(written.audioTracks == earlier.audioTracks)
    #expect(try fixture.original(written) == Data(contentsOf: fixture.input))
  }
}

@Test @MainActor func savedProcessingJobReopensWithoutSubmittingWorkAndResumesOnRequest()
  async throws
{
  try await withLifecycle { fixture, first in
    let initial = try #require(first.state.meeting)
    await first.shutdown()
    // Recreate the durable state after audio was committed and before ASR finished.
    var pending = initial
    let name = "import-00000000.000-" + newID() + ".wav"
    let destination = try fixture.store.meetingDirectory(initial.id).appendingPathComponent(name)
    try FileManager.default.copyItem(at: fixture.input, to: destination)
    pending.audioTracks = [
      AudioTrack(id: "track", label: "Imported audio", filename: name, duration: 1)
    ]
    pending.duration = 1
    pending.status = "processing"
    pending.pendingStage = .recognition
    try fixture.store.save(pending)

    let reopened = try await fixture.open()
    let recovered = try #require(reopened.state.meeting)
    #expect(recovered.status == "interrupted" && recovered.pendingStage == .recognition)
    #expect(recovered.audioTracks == pending.audioTracks)
    #expect(await fixture.speech.recognitionCalls == 0)
    #expect(await fixture.transport.calls == 0)
    _ = try await reopened.handle(action: "resumeProcessing", payload: [:])
    let finished = try fixture.saved(initial.id)
    #expect(finished.status == "complete" && finished.pendingStage == nil)
    #expect(finished.segments.map(\.text) == [fixtureSpeech])
    #expect(await fixture.speech.recognitionCalls == 1)
    #expect(await fixture.transport.calls == 0)
    await reopened.shutdown()
  }
}

@Test @MainActor func failedPolishResumesAfterReopenWithoutRepeatingRecognition() async throws {
  try await withLifecycle(assistantEnabled: true) { fixture, first in
    let id = try #require(first.state.meeting?.id)
    do {
      try await first.importAudio(from: fixture.input)
      Issue.record("The failed polish stage was reported as successful")
    } catch {}
    let failed = try fixture.saved(id)
    #expect(failed.pendingStage == .polish && failed.status == "interrupted")
    #expect(failed.processingError?.isEmpty == false && failed.document == nil)
    #expect(failed.segments.map(\.text) == [fixtureSpeech])
    let drafts = try fixture.store.meetingDirectory(id).appendingPathComponent("document-drafts")
    let draftFiles = try FileManager.default.contentsOfDirectory(
      at: drafts, includingPropertiesForKeys: nil)
    let draftURL = try #require(draftFiles.first)
    let draft = try fixture.store.read(ReadableDocument.self, from: draftURL)
    #expect(draft.text == fixtureSpeech)
    #expect(draft.reviewNotes?.isEmpty == false)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: draftURL.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    let failedCalls = await fixture.transport.calls
    #expect(failedCalls == 1)
    #expect(await fixture.speech.recognitionCalls == 1)
    await first.shutdown()
    let reopened = try await fixture.open()
    #expect(await fixture.transport.calls == failedCalls)
    #expect(reopened.state.meeting?.pendingStage == .polish)
    await fixture.transport.allowRequests()
    _ = try await reopened.handle(action: "resumeProcessing", payload: [:])
    let finished = try fixture.saved(id)
    #expect(
      finished.status == "complete" && finished.pendingStage == nil
        && finished.processingError == nil)
    #expect(finished.document?.text == fixtureSpeech && finished.document?.author == "assistant")
    #expect(finished.segments == failed.segments && finished.audioTracks == failed.audioTracks)
    #expect(finished.recognitionHistory == failed.recognitionHistory)
    #expect(await fixture.speech.recognitionCalls == 1)
    let completedCalls = await fixture.transport.calls
    #expect(completedCalls > failedCalls)
    _ = try await reopened.handle(action: "resumeProcessing", payload: [:])
    #expect(await fixture.transport.calls == completedCalls)
    #expect(await fixture.speech.recognitionCalls == 1)
    await reopened.shutdown()
  }
}

@Test @MainActor func stoppingAcknowledgesLastChunkAndDefersFinalizationUntilAllRecordingStops()
  async throws
{
  try await withLifecycle { fixture, controller in
    let a = try #require(controller.state.meeting?.id)
    _ = try await controller.handle(action: "startRecording", payload: [:])
    await controller.stopRecording()
    let stopped = try fixture.saved(a)
    #expect(stopped.audioTracks.count == 1 && stopped.pendingStage == .recognition)
    #expect(try fixture.original(stopped) == Data(contentsOf: fixture.input))
    _ = try await controller.handle(action: "createMeeting", payload: ["title": "Follow-up"])
    let b = try #require(controller.state.meeting?.id)
    _ = try await controller.handle(action: "startRecording", payload: [:])
    controller.tick()
    await Task.yield()
    #expect(await fixture.speech.recognitionCalls == 0)
    #expect(try fixture.saved(a).pendingStage == .recognition)
    await controller.stopRecording()
    try await waitForLifecycle("both final transcripts") {
      controller.tick()
      return try fixture.saved(a).status == "complete" && fixture.saved(b).status == "complete"
    }
    #expect(await fixture.speech.recognitionCalls == 2)
    #expect(try fixture.saved(a).segments.map(\.text) == [fixtureSpeech])
    #expect(try fixture.saved(b).segments.map(\.text) == [fixtureSpeech])
  }
}

@Test @MainActor func quittingActiveCapturePersistsLastChunkAndExplicitRecognitionStage()
  async throws
{
  try await withLifecycle { fixture, controller in
    let id = try #require(controller.state.meeting?.id)
    _ = try await controller.handle(action: "startRecording", payload: [:])
    await controller.shutdown()
    let meeting = try fixture.saved(id)
    #expect(meeting.status == "interrupted" && meeting.pendingStage == .recognition)
    #expect(meeting.audioTracks.count == 1)
    #expect(try fixture.original(meeting) == Data(contentsOf: fixture.input))
    let reopened = try await fixture.open()
    reopened.tick()
    #expect(await fixture.speech.recognitionCalls == 0)
    #expect(await fixture.transport.calls == 0)
    _ = try await reopened.handle(action: "resumeProcessing", payload: [:])
    #expect(try fixture.saved(id).status == "complete")
    await reopened.shutdown()
  }
}

@Test @MainActor func captureSourceFailuresKeepPartialAudioAndSuppressMisleadingMeters()
  async throws
{
  try await withLifecycle { fixture, controller in
    _ = try await controller.handle(action: "startRecording", payload: [:])
    let id = try #require(controller.state.meeting?.id)
    let system = CaptureIssue(
      source: .systemAudio, kind: .sourceStopped, offset: 0.2,
      duration: 0, message: "System input stopped")
    fixture.capture.report?(system)
    try await waitForLifecycle("system failure") {
      controller.state.runtime.captureHealth?[CaptureSource.systemAudio.rawValue] == "failed"
    }
    fixture.capture.meter?(0.9, true)
    fixture.capture.meter?(0.4, false)
    try await waitForLifecycle("working microphone meter") {
      controller.state.runtime.inputLevel == 0.4
    }
    #expect(controller.state.runtime.systemLevel == 0 && controller.state.runtime.recording)
    let mic = CaptureIssue(
      source: .microphone, kind: .writeFailed, offset: 0.8,
      duration: 0, message: "Microphone write failed")
    fixture.capture.report?(mic)
    try await waitForLifecycle("microphone shutdown") { !controller.state.runtime.recording }
    let interrupted = try fixture.saved(id)
    #expect(interrupted.captureIssues == [system, mic])
    #expect(interrupted.processingError == mic.message && interrupted.pendingStage == .recognition)
    #expect(interrupted.status == "interrupted" && controller.state.runtime.inputLevel == 0)
    #expect(try fixture.original(interrupted) == Data(contentsOf: fixture.input))
    controller.tick()
    #expect(await fixture.speech.recognitionCalls == 0)
  }
}

@Test @MainActor func slowLiveWriterDoesNotBlockMeterTicksAndPublishesParagraphs() async throws {
  try await withLifecycle(assistantEnabled: true) { fixture, controller in
    await fixture.transport.allowRequests()
    await fixture.transport.pauseNextRequest()
    defer { Task { await fixture.transport.releaseRequest() } }
    _ = try await controller.handle(action: "startRecording", payload: [:])
    _ = try await controller.handle(
      action: "addPassage", payload: ["text": "Discuss the schedule."])
    let id = try #require(controller.state.meeting?.id)
    let before = try fixture.saved(id)
    var durations: [Double] = []
    controller.onRecordingTick = { _, duration, _ in durations.append(duration) }
    controller.tick()
    try await waitForLifecycle("blocked assistant") { await fixture.transport.isWaiting }
    controller.tick()
    controller.tick()
    #expect(durations.count >= 3)
    #expect(try fixture.saved(id).duration == before.duration)
    await fixture.transport.releaseRequest()
    try await waitForLifecycle("live assistant completion") {
      controller.state.runtime.assistantStatus == "Ready"
    }
    // One live writer, followed by the separately scheduled forecast.
    #expect(await fixture.transport.calls == 2)
    #expect(controller.state.meeting?.document?.text == "Discuss the schedule.")
  }
}

@Test @MainActor func editedMeetingFinishesOnlyNewAudioAndPreservesOriginalEvidence() async throws {
  try await withLifecycle { fixture, controller in
    try await controller.importAudio(from: fixture.input)
    let imported = try #require(controller.state.meeting)
    let original = try #require(imported.segments.first)
    _ = try await controller.handle(
      action: "editSegment",
      payload: ["id": original.id, "revision": original.revision, "text": "A corrected date."])
    let edited = try #require(controller.state.meeting)
    _ = try await controller.handle(
      action: "editDocument",
      payload: [
        "text": "My edited reading notes.", "revision": 0,
        "baseFingerprint": transcriptFingerprint(edited.segments),
      ])
    let protected = try #require(controller.state.meeting)
    await fixture.speech.failNextRecognition()
    _ = try await controller.handle(action: "startRecording", payload: [:])
    await controller.stopRecording()
    try await waitForLifecycle("retryable protected recording") {
      controller.tick()
      return try fixture.saved(protected.id).status == "interrupted"
    }
    let failed = try fixture.saved(protected.id)
    let newTrack = try #require(failed.audioTracks.last)
    #expect(failed.audioTracks.count == 2 && failed.pendingStage == .recognition)
    #expect(failed.document == protected.document && failed.segments == protected.segments)
    #expect(failed.recognitionHistory == protected.recognitionHistory)
    #expect(await fixture.speech.lastTrackIDs == [newTrack.id])
    _ = try await controller.handle(action: "resumeProcessing", payload: [:])
    let finished = try fixture.saved(protected.id)
    #expect(finished.status == "ready" && finished.pendingStage == nil)
    #expect(finished.recognitionNotice?.isEmpty == false && finished.processingError == nil)
    #expect(
      finished.document == protected.document
        && finished.documentHistory == protected.documentHistory)
    #expect(finished.recognitionHistory?.last?.segments == protected.segments)
    #expect(
      finished.audioTracks == failed.audioTracks
        && finished.preparedRecording == protected.preparedRecording)
    #expect(finished.protectedPassTrackIDs == [newTrack.id])
    #expect(finished.segments.first == protected.segments.first)
    let appended = try #require(finished.segments.last)
    #expect(finished.segments.count == 2 && appended.start >= protected.duration)
    #expect(await fixture.speech.lastTrackIDs == [newTrack.id])
    #expect(await fixture.speech.recognitionCalls == 3)
    _ = try await controller.handle(action: "reprocessAudio", payload: [:])
    #expect(await fixture.speech.recognitionCalls == 3)
    #expect(try fixture.saved(protected.id).segments == finished.segments)
    #expect(await fixture.transport.calls == 0)
  }
}

@Test @MainActor func protectedLiveTrackKeepsItsOtherTurnsAndReplacesOnlyNewProvisionalSpeech()
  async throws
{
  try await withLifecycle { fixture, first in
    var meeting = try #require(first.state.meeting)
    await first.shutdown()
    let directory = try fixture.store.meetingDirectory(meeting.id)
    for (i, name) in ["mic-00000.000-old.wav", "mic-00001.000-new.wav"].enumerated() {
      try FileManager.default.copyItem(
        at: fixture.input, to: directory.appendingPathComponent(name))
      meeting.audioTracks.append(
        AudioTrack(id: "track-\(i)", label: "Microphone", filename: name, duration: 1))
    }
    func speech(_ id: String, at start: Double, text: String, status: String) -> Segment {
      Segment(
        id: id, start: start, end: start + 0.4, speaker: "Microphone", rawText: text, text: text,
        status: status, revision: 0, corrections: [])
    }
    let manual = speech("track-0:0", at: 0, text: "Authoritative.", status: "manual")
    let neighbor = speech("track-0:1", at: 0.5, text: "Existing neighboring turn.", status: "raw")
    let provisional = speech("track-1:0", at: 1, text: "Provisional.", status: "raw")
    meeting.segments = [manual, neighbor, provisional]
    meeting.pendingStage = .recognition
    meeting.status = "interrupted"
    meeting.duration = 2
    try fixture.store.save(meeting)
    let reopened = try await fixture.open()
    _ = try await reopened.handle(action: "resumeProcessing", payload: [:])
    let finished = try fixture.saved(meeting.id)
    #expect(await fixture.speech.lastTrackIDs == ["track-1"])
    #expect(finished.segments.count == 3)
    #expect(Array(finished.segments.prefix(2)) == [manual, neighbor])
    #expect(finished.segments.last?.start == 1 && finished.segments.last?.text == fixtureSpeech)
    #expect(finished.recognitionHistory?.last?.segments == meeting.segments)
    #expect(finished.protectedPassTrackIDs == ["track-1"])
    #expect(finished.pendingStage == nil && finished.recognitionNotice != nil)
    await reopened.shutdown()
  }
}

@Test @MainActor func firstImportWritesAvailableRecognitionAndSurvivesReopen() async throws {
  try await withLifecycle(assistantEnabled: true) { fixture, first in
    await fixture.transport.allowRequests()
    await fixture.speech.setCoverage(false, verified: false)
    try await first.importAudio(from: fixture.input)
    let written = try #require(first.state.meeting)
    #expect(written.status == "complete" && written.pendingStage == nil)
    #expect(written.processingError == nil && written.recognitionDraft == nil)
    #expect(written.segments.map(\.text) == ["Incomplete fragment."])
    #expect(written.document?.text == fixtureSpeech)
    #expect(written.recognitionNotice?.contains("Detected speech was omitted") == true)
    #expect(written.preparedRecording != nil)
    #expect(
      written.recognitionAlternatives?.first?.text
        == "Independent recognition of the Friday review.")
    await first.shutdown()

    let reopened = try await fixture.open()
    #expect(reopened.state.meeting?.document == written.document)
    #expect(await fixture.speech.recognitionCalls == 1)
    #expect(await fixture.transport.calls == 1)
    _ = try await reopened.handle(action: "addPassage", payload: ["text": "My typed note."])
    await fixture.speech.setCoverage(true)
    _ = try await reopened.handle(action: "reprocessAudio", payload: [:])
    let refreshed = try fixture.saved(written.id)
    #expect(refreshed.status == "complete" && refreshed.pendingStage == nil)
    #expect(refreshed.recognitionHistory?.last?.segments.contains(written.segments[0]) == true)
    #expect(refreshed.documentHistory?.last == written.document)
    #expect(refreshed.segments.map(\.text) == [fixtureSpeech, "My typed note."])
    #expect(refreshed.audioTracks == written.audioTracks)
    #expect(try fixture.original(refreshed) == Data(contentsOf: fixture.input))
    #expect(await fixture.speech.recognitionCalls == 2)
    await reopened.shutdown()
  }
}

@Test @MainActor func streamingFinalWaitsForAcknowledgmentAndPreservesUserEdits() async throws {
  try await withLifecycle(live: true) { fixture, controller in
    let id = try #require(controller.state.meeting?.id)
    _ = try await controller.handle(action: "startRecording", payload: [:])
    await #expect(throws: AsideError.self) {
      _ = try await controller.handle(
        action: "updateSettings", payload: ["contextualCaptions": false])
    }
    try fixture.capture.send(at: 0)
    try await waitForLifecycle("stable live words") {
      controller.state.meeting?.segments.count == 1
    }
    let first = try #require(controller.state.meeting?.segments.first)
    _ = try await controller.handle(
      action: "editSegment",
      payload: ["id": first.id, "text": "Keep the correction.", "revision": 0])
    _ = try await controller.handle(action: "addPassage", payload: ["text": "Typed note."])
    let session = try #require(await fixture.speech.sessions.first)
    await session.holdFinish()
    await controller.stopRecording()
    try await waitForLifecycle("blocked terminal publication") { await session.finishing }
    let directory = try fixture.store.meetingDirectory(id)
    let ledger = directory.appendingPathComponent("transcribed.json")
    let reserved = directory.appendingPathComponent("caption-pending.json")
    #expect(!FileManager.default.fileExists(atPath: ledger.path))
    let stopped = try fixture.saved(id)
    #expect(stopped.audioTracks.count == 2 && stopped.segments.count == 3)
    #expect(stopped.segments.first(where: { $0.id == first.id })?.text == "Keep the correction.")
    #expect(
      try fixture.store.read(Set<String>.self, from: reserved) == Set(stopped.audioTracks.map(\.id))
    )
    _ = try await controller.handle(action: "createMeeting", payload: ["title": "Next meeting"])
    let second = try #require(controller.state.meeting?.id)
    _ = try await controller.handle(action: "startRecording", payload: [:])
    controller.tick()
    #expect(await fixture.speech.recognitionCalls == 0)
    await session.allowFinish()
    try fixture.capture.send(at: 0)
    try await waitForLifecycle("separate meeting stream") {
      controller.state.meeting?.segments.count == 1
    }
    #expect(
      try fixture.store.read(Set<String>.self, from: ledger) == Set(stopped.audioTracks.map(\.id)))
    await #expect(throws: CancellationError.self) { try await session.sendStaleUpdate() }
    #expect(try fixture.saved(second).segments.allSatisfy { $0.text == "Caption 1" })
    #expect(await fixture.speech.recognitionCalls == 0)
    await controller.stopRecording()
    try await waitForLifecycle("both final passes") {
      controller.tick()
      return try fixture.saved(id).pendingStage == nil && fixture.saved(second).pendingStage == nil
    }
    let finished = try fixture.saved(id)
    #expect(finished.segments.filter(\.isNote) == stopped.segments.filter(\.isNote))
    #expect(
      finished.segments.first(where: { $0.id == first.id })
        == stopped.segments.first(where: { $0.id == first.id }))
    #expect(await fixture.speech.liveCalls == 0)
  }
}

@Test @MainActor func failedPartialStreamCannotReplayFreshWordsAfterReopen() async throws {
  try await withLifecycle(live: true, failStream: true) { fixture, controller in
    let id = try #require(controller.state.meeting?.id)
    _ = try await controller.handle(action: "startRecording", payload: [:])
    try fixture.capture.send(at: 0)
    try await waitForLifecycle("partial caption failure") {
      controller.state.runtime.lastError?.contains("Decoder failure") == true
    }
    await controller.shutdown()
    let broken = try fixture.saved(id)
    #expect(broken.status == "interrupted" && broken.pendingStage == .recognition)
    #expect(broken.segments.map(\.text) == ["Caption 1"] && broken.audioTracks.count == 2)
    let reserved = try fixture.store.meetingDirectory(id).appendingPathComponent(
      "caption-pending.json")
    #expect(
      try fixture.store.read(Set<String>.self, from: reserved) == Set(broken.audioTracks.map(\.id)))
    let reopened = try await fixture.open()
    _ = try await reopened.handle(action: "retranscribe", payload: [:])
    #expect(await fixture.speech.liveCalls == 0)
    #expect(try fixture.saved(id).segments == broken.segments)
    _ = try await reopened.handle(action: "resumeProcessing", payload: [:])
    #expect(try fixture.saved(id).recognitionHistory?.last?.segments == broken.segments)
    #expect(try fixture.store.read(Set<String>.self, from: reserved).isEmpty)
    #expect(await fixture.speech.recognitionCalls == 1)
    await reopened.shutdown()
  }
}

@Test @MainActor func clockGapsAndIndependentAudioSourcesGetSeparateDecoders() async throws {
  try await withLifecycle(live: true) { fixture, controller in
    _ = try await controller.handle(action: "startRecording", payload: [:])
    try fixture.capture.send(at: 0)
    try await waitForLifecycle("first source") { controller.state.meeting?.segments.count == 1 }
    try fixture.capture.send(at: 0, source: "System audio")
    try await waitForLifecycle("system source") { controller.state.meeting?.segments.count == 2 }
    try fixture.capture.send(at: 5)
    try await waitForLifecycle("new microphone clock") {
      controller.state.meeting?.segments.count == 3
    }
    await controller.shutdown()
    let value = try #require(controller.state.meeting)
    let sessions = await fixture.speech.sessions
    #expect(sessions.count == 3 && Set(sessions.map(\.generation)).count == 3)
    #expect(value.segments.map(\.start).sorted() == [0, 0, 5, 6])
    #expect(value.segments.filter { $0.speaker == "System audio" }.count == 1)
    let ledger = try fixture.store.meetingDirectory(value.id).appendingPathComponent(
      "transcribed.json")
    #expect(
      try fixture.store.read(Set<String>.self, from: ledger) == Set(value.audioTracks.map(\.id)))
    #expect(await fixture.speech.recognitionCalls == 0)
    #expect(await fixture.speech.liveCalls == 0)
  }
}

@Test @MainActor func unsupportedLiveFactoryFallsBackOnlyBeforeStreaming() async throws {
  try await withLifecycle(live: true, supportsStreaming: false) { fixture, controller in
    _ = try await controller.handle(action: "startRecording", payload: [:])
    try fixture.capture.send(at: 0)
    await controller.stopRecording()
    try await waitForLifecycle("fresh fallback") { controller.state.meeting?.segments.count == 2 }
    #expect(await fixture.speech.liveCalls == 2)
    #expect(await fixture.speech.factoryCalls == 1)
    _ = try await controller.handle(
      action: "updateSettings", payload: ["contextualCaptions": false])
    _ = try await controller.handle(
      action: "createMeeting", payload: ["title": "Ordinary captions"])
    _ = try await controller.handle(action: "startRecording", payload: [:])
    await controller.stopRecording()
    try await waitForLifecycle("explicit fresh mode") { await fixture.speech.liveCalls == 3 }
    #expect(await fixture.speech.factoryCalls == 1)
  }
}

@Test @MainActor func protectedContextualCaptionKeepsBothSameSourceBoundaryTracks() async throws {
  try await withLifecycle { fixture, controller in
    var meeting = try #require(controller.state.meeting)
    await controller.shutdown()
    let directory = try fixture.store.meetingDirectory(meeting.id)
    let sources = ["Microphone", "Microphone", "Microphone", "System audio"]
    let offsets = [0, 1, 2, 1]
    for index in sources.indices {
      let prefix = index == 3 ? "system" : "mic"
      let name = String(format: "%@-%012.3f-%d.wav", prefix, Double(offsets[index]), index)
      try FileManager.default.copyItem(
        at: fixture.input, to: directory.appendingPathComponent(name))
      meeting.audioTracks.append(
        AudioTrack(id: "track-" + String(index), label: sources[index], filename: name, duration: 1)
      )
    }
    let edited = Segment(
      id: "track-0:-4", start: 0.8, end: 1.12, speaker: "Microphone",
      rawText: "Original.", text: "Corrected.", status: "manual", revision: 1, corrections: [])
    meeting.segments = [edited]
    meeting.pendingStage = .recognition
    meeting.status = "interrupted"
    try fixture.store.save(meeting)
    let reopened = try await fixture.open()
    _ = try await reopened.handle(action: "resumeProcessing", payload: [:])
    let submitted = await fixture.speech.lastTrackIDs
    #expect(Set(submitted) == ["track-2", "track-3"])
    #expect(try fixture.saved(meeting.id).segments.contains(edited))
    await reopened.shutdown()
  }
}

@Test @MainActor func coldSecondaryModelsDoNotDelayTheLiveWriter() async throws {
  try await withLifecycle(assistantEnabled: true, slowWarmup: true) { fixture, controller in
    await fixture.transport.allowRequests()
    defer { Task { await fixture.speech.releaseWarmup() } }
    _ = try await controller.handle(action: "startRecording", payload: [:])
    try await waitForLifecycle("secondary models warming") { await fixture.speech.isWarming }
    _ = try await controller.handle(
      action: "addPassage", payload: ["text": "Discuss the schedule."])
    controller.tick()
    try await waitForLifecycle("live prose while models warm") {
      controller.state.meeting?.document != nil
    }
    #expect(await fixture.speech.isWarming)
    #expect(controller.state.runtime.recording)
    await fixture.speech.releaseWarmup()
  }
}

@Test @MainActor func explicitLivePolishStaysFastAndFinalWriterStartsOnlyAfterStop() async throws {
  try await withLifecycle(assistantEnabled: true) { fixture, controller in
    await fixture.transport.allowRequests()
    _ = try await controller.handle(action: "startRecording", payload: [:])
    _ = try await controller.handle(
      action: "addPassage", payload: ["text": "Discuss the schedule."])
    _ = try await controller.handle(action: "runAssistant", payload: ["anticipate": false])
    #expect(await fixture.transport.providers == ["claude-cli"])
    #expect(controller.state.runtime.recording)
    await controller.stopRecording()
    try await waitForLifecycle("post-meeting final writer") {
      controller.tick()
      return controller.state.meeting?.status == "complete"
    }
    #expect(await fixture.transport.providers.last == "codex-terra")
    #expect(await fixture.transport.providers.filter { $0 == "codex-terra" }.count == 1)
  }
}

@Test @MainActor func preparingContextDoesNotRewriteTheFinishedTranscript() async throws {
  try await withLifecycle(assistantEnabled: true) { fixture, controller in
    await fixture.transport.allowRequests()
    try await controller.importAudio(from: fixture.input)
    let before = try #require(controller.state.meeting)
    let calls = await fixture.transport.calls
    #expect(before.status == "complete" && before.document != nil)
    _ = try await controller.handle(
      action: "runAssistant", payload: ["repair": false, "anticipate": true])
    let after = try #require(controller.state.meeting)
    #expect(await fixture.transport.calls == calls + 1)
    #expect(await fixture.transport.providers.last == "claude-cli")
    #expect(after.document == before.document && after.documentHistory == before.documentHistory)
    #expect(after.status == before.status && after.pendingStage == nil)
  }
}

@Test(arguments: [false, true])
@MainActor func explicitQuestionsRunAlongsideTheLiveWriter(backgroundFinishesFirst: Bool)
  async throws
{
  try await withLifecycle(assistantEnabled: true) { fixture, controller in
    await fixture.transport.allowRequests()
    await fixture.transport.pauseNextRequest()
    await fixture.transport.pauseQuestions()
    defer {
      Task {
        await fixture.transport.releaseQuestion()
        await fixture.transport.releaseRequest()
      }
    }
    _ = try await controller.handle(action: "startRecording", payload: [:])
    _ = try await controller.handle(
      action: "addPassage", payload: ["text": "Discuss Friday's draft."])
    controller.tick()
    try await waitForLifecycle("blocked background writer") { await fixture.transport.isWaiting }
    let backgroundStatus = controller.state.runtime.assistantStatus
    let question = Task {
      try await controller.handle(action: "ask", payload: ["question": "When is the draft review?"])
    }
    try await waitForLifecycle("question beside writer") {
      await fixture.transport.isQuestionWaiting
    }
    #expect(controller.state.runtime.answering == true)
    #expect(controller.state.runtime.assistantView == "ask")
    #expect(controller.state.runtime.assistantStatus == backgroundStatus)
    do {
      _ = try await controller.handle(action: "ask", payload: ["question": "Duplicate request"])
      Issue.record("A duplicate question should not start a second request")
    } catch { #expect(error.localizedDescription.contains("already being answered")) }
    if backgroundFinishesFirst {
      await fixture.transport.releaseRequest()
      try await waitForLifecycle("background completion during question") {
        controller.state.runtime.assistantStatus == "Ready"
      }
      #expect(controller.state.meeting?.document != nil)
      _ = try await controller.handle(
        action: "addPassage", payload: ["text": "New unrelated speech."])
      #expect(controller.state.runtime.answering == true)
    }
    await fixture.transport.releaseQuestion()
    _ = try await question.value
    #expect(controller.state.runtime.answering == false)
    #expect(controller.state.runtime.assistantView == "ask")
    #expect(controller.state.meeting?.messages.map(\.role) == ["user", "assistant"])
    #expect(controller.state.meeting?.messages.last?.text == "The draft review is Friday.")
    if !backgroundFinishesFirst {
      #expect(controller.state.runtime.assistantStatus == backgroundStatus)
      await fixture.transport.releaseRequest()
      try await waitForLifecycle("writer after answer") {
        controller.state.runtime.assistantStatus == "Ready"
      }
    }
    #expect(await fixture.transport.calls == 3)
  }
}

@Test @MainActor func quittingCancelsTheIndependentQuestionAndClearsItsSharedState() async throws {
  try await withLifecycle(assistantEnabled: true) { fixture, controller in
    await fixture.transport.allowRequests()
    await fixture.transport.pauseQuestions()
    defer { Task { await fixture.transport.releaseQuestion() } }
    let question = Task {
      try await controller.handle(action: "ask", payload: ["question": "What should I read?"])
    }
    try await waitForLifecycle("question in flight") { await fixture.transport.isQuestionWaiting }
    #expect(controller.state.runtime.answering == true)
    await controller.shutdown()
    do {
      _ = try await question.value
      Issue.record("Shutdown should cancel the pending question")
    } catch { #expect(error is CancellationError) }
    #expect(await fixture.transport.questionCancelled)
    #expect(controller.state.runtime.answering == false)
    #expect(controller.state.meeting?.messages.map(\.role) == ["user"])
  }
}

@Test @MainActor func offlineRecognitionWaitsForWarmupWithoutBlockingTheInterface() async throws {
  try await withLifecycle(assistantEnabled: true, slowWarmup: true) { fixture, controller in
    await fixture.transport.allowRequests()
    defer { Task { await fixture.speech.releaseWarmup() } }
    _ = try await controller.handle(action: "startRecording", payload: [:])
    try await waitForLifecycle("recording warmup") { await fixture.speech.isWarming }
    _ = try await controller.handle(action: "stopRecording", payload: [:])
    try await waitForLifecycle("offline warmup status") {
      controller.state.runtime.assistantStatus == "Preparing speech models"
    }
    #expect(await fixture.speech.recognitionCalls == 0)
    #expect(controller.state.meeting?.audioTracks.count == 1)
    _ = try await controller.handle(action: "getState", payload: [:])
    #expect(controller.state.runtime.assistantStatus == "Preparing speech models")
    await fixture.speech.releaseWarmup()
    try await waitForLifecycle("recorded audio finalized") {
      controller.state.meeting?.status == "complete"
    }
    #expect(await fixture.speech.recognitionCalls == 1)
  }
}

@Test @MainActor
func readingSavedMeetingsKeepsSpeechColdAndOfflineWorkRetiresItsModels() async throws {
  try await withLifecycle(assistantEnabled: true, slowWarmup: true) { fixture, controller in
    await fixture.transport.allowRequests()
    try await waitForLifecycle("installed model status") {
      controller.state.runtime.finalModelStatus == "ready"
    }
    #expect(await fixture.speech.finalPreparationCalls == 0)
    #expect(await !fixture.speech.isWarming)
    try await controller.importAudio(from: fixture.input)
    #expect(await fixture.speech.recognitionCalls == 1)
    #expect(await fixture.speech.retirementCalls == 1)
    #expect(controller.state.meeting?.status == "complete")
  }
}

@Test @MainActor func anActiveRecordingCannotBeMovedToTrash() async throws {
  try await withLifecycle { fixture, controller in
    let id = try #require(controller.state.meeting?.id)
    _ = try await controller.handle(action: "startRecording", payload: [:])
    do {
      _ = try await controller.handle(action: "deleteMeeting", payload: ["id": id])
      Issue.record("An active recording should remain available to capture")
    } catch {}
    #expect(controller.state.runtime.recording)
    #expect(controller.state.meeting?.id == id)
    #expect(FileManager.default.fileExists(atPath: try fixture.store.meetingDirectory(id).path))
  }
}
