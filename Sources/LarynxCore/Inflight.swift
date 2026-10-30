import AVFoundation
import Foundation

/// Audio being recorded, streamed to ~/.larynx/inflight/<id>.caf so a crash loses nothing.
/// The file is deleted as soon as its text is in history.
public enum Inflight {
    public static var dir: URL { Paths.home.appendingPathComponent("inflight", isDirectory: true) }

    public static func url(for id: String) -> URL { dir.appendingPathComponent("\(id).caf") }

    /// Leftover files from a run that died, oldest first.
    public static func leftovers() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "caf" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
    }

    /// Reads a CAF as 16 kHz mono samples. Our own files are read byte for byte, so a file
    /// cut off mid-write by a crash gives back every whole sample. Others go through AVAudioFile.
    public static func read(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let header = CafWriter.header
        if data.count >= header.count, data.prefix(header.count) == header {
            let whole = (data.count - header.count) / 4 * 4
            return data.subdata(in: header.count..<(header.count + whole)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
    }

    public struct Recovered: Sendable {
        public let file: URL
        public let dictation: Dictation?
        public let error: String?
    }

    /// Turns every leftover file into a history row (landed = clipboard), then deletes it.
    /// A file whose text comes back empty is deleted too. A file that fails to transcribe stays for next time.
    /// Pass the list taken at launch, so a recording that starts meanwhile is never touched.
    public static func recover(_ files: [URL], model: String, history: History, clipboard: Clipboard,
                               transcribe: ([Float]) async throws -> String) async -> [Recovered] {
        var out: [Recovered] = []
        for file in files {
            do {
                let samples = try read(file)
                let text = samples.isEmpty ? "" : try await transcribe(samples)
                var saved: Dictation?
                if !text.isEmpty {
                    let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    let d = Dictation(id: file.deletingPathExtension().lastPathComponent, createdAt: created,
                                      textRaw: text, model: model, durationS: Double(samples.count) / 16_000)
                    saved = try handOver(d, history: history, clipboard: clipboard)
                }
                try? FileManager.default.removeItem(at: file)
                out.append(Recovered(file: file, dictation: saved, error: nil))
            } catch {
                out.append(Recovered(file: file, dictation: nil, error: "\(error)"))
            }
        }
        return out
    }
}

/// Writes 16 kHz mono Float32 samples to a CAF file as they arrive. The header says
/// "data runs to the end of the file", so a file cut short by a crash still reads back.
public final class CafWriter {
    public static let sampleRate = 16_000.0
    public let url: URL
    private let handle: FileHandle
    public private(set) var samples = 0

    public init(url: URL) throws {
        self.url = url
        try Paths.ensurePrivateDir(url.deletingLastPathComponent())
        guard FileManager.default.createFile(atPath: url.path, contents: CafWriter.header,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    /// Big-endian CAF header: 'caff', 'desc' (lpcm float32 LE, 16 kHz, mono), 'data' with size -1.
    static var header: Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func i64(_ v: Int64) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func tag(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        tag("caff"); u16(1); u16(0)
        tag("desc"); i64(32)
        withUnsafeBytes(of: sampleRate.bitPattern.bigEndian) { d.append(contentsOf: $0) }
        tag("lpcm")
        u32(3)  // kCAFLinearPCMFormatFlagIsFloat | kCAFLinearPCMFormatFlagIsLittleEndian
        u32(4); u32(1); u32(1); u32(32) // bytes/packet, frames/packet, channels, bits
        tag("data"); i64(-1)
        u32(0)  // edit count
        return d
    }

    public func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        chunk.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
        samples += chunk.count
    }

    public func close() { try? handle.close() }
}
