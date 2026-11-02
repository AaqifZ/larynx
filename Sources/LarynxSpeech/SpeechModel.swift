import FluidAudio
import Foundation
import LarynxCore

/// The speech models Larynx knows. Pick one in larynx.toml with `model = "..."`.
/// Adding a model is one line here. Loading is disk only; fetching lives in the CLI.
public struct SpeechModel: Sendable {
    public let name: String
    public let version: AsrModelVersion
    public let repo: Repo

    public static let all: [SpeechModel] = [
        SpeechModel(name: "parakeet-v3", version: .v3, repo: .parakeetV3),        // baseline
        SpeechModel(name: "parakeet-ultra", version: .ultra, repo: .parakeetUltra),
        SpeechModel(name: "parakeet-v2", version: .v2, repo: .parakeetV2),
    ]

    public static func named(_ name: String) throws -> SpeechModel {
        guard let m = all.first(where: { $0.name == name }) else {
            throw SpeechError("unknown model \"\(name)\" in larynx.toml; known: \(all.map(\.name).joined(separator: ", "))")
        }
        return m
    }

    /// ~/.larynx/models/<repo folder>
    public var directory: URL { Paths.models.appendingPathComponent(repo.folderName, isDirectory: true) }

    public var isPresent: Bool { AsrModels.modelsExist(at: directory, version: version) }

    /// Bytes on disk, for `status` and `models fetch`.
    public var bytesOnDisk: Int64 {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Turns off FluidAudio's own download paths in this process. Only `larynx models fetch` downloads.
    public static func refuseDownloads() { ModelHub.offlineMode = true }

    /// Loads from disk only. Never downloads: missing files are an error.
    public func load() throws -> AsrModels {
        Self.refuseDownloads()
        guard isPresent else {
            throw SpeechError("speech model \(name) is not on this Mac. Run `larynx models fetch` once; it is the only command that uses the network.")
        }
        return try AsrModels.loadLocal(from: directory, version: version)
    }
}

public struct SpeechError: Error, CustomStringConvertible {
    public let description: String
    public init(_ m: String) { description = m }
}

/// One loaded model, kept warm. Calls are serialised by the actor, so the live preview
/// and the final transcription never run at the same time.
public actor Transcriber {
    public let model: SpeechModel
    private var manager: AsrManager?

    public init(model: SpeechModel) { self.model = model }

    private var tail: Task<Void, Never>?

    public var isLoaded: Bool { manager != nil }

    /// Runs model calls one after another. Actor methods can interleave at `await`,
    /// so a plain actor is not enough to keep two transcriptions apart.
    private func serial<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let prev = tail
        let task = Task { () async throws -> T in
            _ = await prev?.value
            return try await op()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    public func load() async throws {
        if manager != nil { return }
        let models = try model.load()
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        manager = m
    }

    /// 16 kHz mono samples to text. Pads very short audio with silence (the model needs 1 s).
    public func transcribe(_ samples: [Float]) async throws -> String {
        try await load()
        guard let manager else { throw SpeechError("speech model not loaded") }
        let layers = model.version.decoderLayers
        return try await serial {
            var s = samples
            let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
            if s.count < minimum { s += [Float](repeating: 0, count: minimum - s.count) }
            var state = try TdtDecoderState(decoderLayers: layers)
            let result = try await manager.transcribe(s, decoderState: &state)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Any audio file to 16 kHz mono samples.
    public static func samples(of url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}
