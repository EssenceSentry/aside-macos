import AVFoundation
import Foundation

/// Exports one capture source at a time. Independently shortened sources must
/// never be mixed by compressed position: their time maps can differ.
enum RecordingExport {
  static func sourceName(_ label: String) -> String {
    label.lowercased().replacingOccurrences(
      of: "[^a-z0-9-]", with: "-", options: .regularExpression)
  }
  static func preparedURL(meeting: Meeting, directory: URL, source: String) -> URL? {
    guard let prepared = meeting.preparedRecording,
      UUID(uuidString: prepared.passID) != nil,
      prepared.trackIDs.sorted() == meeting.audioTracks.map(\.id).sorted(),
      meeting.audioTracks.contains(where: { $0.label == source })
    else { return nil }
    let url = directory.appendingPathComponent(
      "derived/\(prepared.passID)/\(sourceName(source))-prepared.wav")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
  static func sources(meeting: Meeting, directory: URL) -> [AudioExportSource] {
    Set(meeting.audioTracks.map(\.label)).sorted().map {
      AudioExportSource(
        label: $0,
        preparedAvailable: preparedURL(meeting: meeting, directory: directory, source: $0) != nil)
    }
  }
  static func write(
    meeting: Meeting, directory: URL, source: String, prepared: Bool, to output: URL
  ) throws {
    let workspace = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let destination = output.resolvingSymlinksInPath().standardizedFileURL.path
    guard !destination.hasPrefix(workspace + "/"), destination != workspace else {
      throw AsideError("Choose a destination outside the saved meeting")
    }
    let temporary = output.deletingLastPathComponent().appendingPathComponent(
      ".aside-export-" + newID() + ".wav")
    defer { try? FileManager.default.removeItem(at: temporary) }
    if prepared {
      guard let input = preparedURL(meeting: meeting, directory: directory, source: source) else {
        throw AsideError(
          "Prepare the current recording with Improve recognition from saved audio first")
      }
      // A byte-for-byte copy of the actual recognizer input, rather than another
      // encoding or a synthetic recording of the repaired transcript.
      try FileManager.default.copyItem(at: input, to: temporary)
    } else {
      try original(meeting: meeting, directory: directory, source: source, to: temporary)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if FileManager.default.fileExists(atPath: output.path) {
      _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: output)
    }
  }
  private static func original(meeting: Meeting, directory: URL, source: String, to output: URL)
    throws
  {
    let tracks = meeting.audioTracks.filter { $0.label == source }.sorted {
      ChunkWriter.offset(for: $0.filename) < ChunkWriter.offset(for: $1.filename)
    }
    guard !tracks.isEmpty else { throw AsideError("This meeting has no audio for that source") }
    // Preserve the highest recorded sample rate and channel count for this
    // source, including recordings resumed after an input-device change.
    let formats = try tracks.map {
      try AVAudioFile(forReading: directory.appendingPathComponent($0.filename)).processingFormat
    }
    let rate = formats.map(\.sampleRate).max() ?? 48000
    let channels = formats.map(\.channelCount).max() ?? 1
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
      meeting.duration.isFinite, meeting.duration >= 0,
      meeting.duration * rate * Double(channels) * 4 < Double(UInt32.max) - 4096
    else { throw AsideError("This recording exceeds the WAV export size limit") }
    var file: AVAudioFile? = try AVAudioFile(forWriting: output, settings: format.settings)
    // Closing before publishing finalizes the WAV header, including its duration.
    defer { file = nil }
    guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else {
      throw AsideError("Could not allocate audio export buffer")
    }
    for channel in 0..<Int(channels) {
      memset(silence.floatChannelData![channel], 0, 32768 * MemoryLayout<Float>.size)
    }
    var cursor: Int64 = 0
    func pad(to position: Int64) throws {
      while cursor < position {
        silence.frameLength = AVAudioFrameCount(min(32768, position - cursor))
        try file?.write(from: silence)
        cursor += Int64(silence.frameLength)
      }
    }
    for track in tracks {
      let input = try AVAudioFile(forReading: directory.appendingPathComponent(track.filename))
      let offset = ChunkWriter.offset(for: track.filename)
      guard offset.isFinite, offset >= 0,
        (offset + Double(input.length) / input.processingFormat.sampleRate) * rate
          * Double(channels) * 4 < Double(UInt32.max) - 4096,
        let converter = AVAudioConverter(from: input.processingFormat, to: format),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768)
      else { throw AsideError("This audio source cannot be exported as WAV") }
      let position = Int64((offset * rate).rounded())
      try pad(to: position)
      // Millisecond chunk offsets can overlap by a few samples. Retain timeline
      // position rather than duplicating samples and drifting on every chunk.
      var skip = max(0, cursor - position)
      var readError: Error?
      while true {
        var conversionError: NSError?
        let status = converter.convert(to: buffer, error: &conversionError) { count, status in
          guard input.framePosition < input.length else {
            status.pointee = .endOfStream
            return nil
          }
          guard
            let block = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count)
          else {
            readError = AsideError("Could not allocate audio input buffer")
            status.pointee = .endOfStream
            return nil
          }
          do {
            try input.read(into: block, frameCount: count)
            status.pointee = .haveData
            return block
          } catch {
            readError = error
            status.pointee = .endOfStream
            return nil
          }
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        if status == .error { throw AsideError("Audio export conversion failed") }
        let drop = min(skip, Int64(buffer.frameLength))
        skip -= drop
        let count = Int(buffer.frameLength) - Int(drop)
        if count > 0 {
          for channel in 0..<Int(channels) where drop > 0 {
            memmove(
              buffer.floatChannelData![channel],
              buffer.floatChannelData![channel].advanced(by: Int(drop)),
              count * MemoryLayout<Float>.size)
          }
          buffer.frameLength = AVAudioFrameCount(count)
          try file?.write(from: buffer)
          cursor += Int64(count)
        }
        if status == .endOfStream { break }
      }
    }
    try pad(to: Int64((meeting.duration * rate).rounded(.up)))
    file = nil
  }
}
