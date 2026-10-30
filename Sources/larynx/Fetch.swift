import FluidAudio
import Foundation
import LarynxCore
import LarynxSpeech

typealias CLIError = SpeechError

extension SpeechModel {
    /// The ONLY network path in Larynx: fetch weights from Hugging Face. Sends no user data.
    /// It lives in the CLI, never in the app.
    /// Downloads at the commit pinned in ModelManifest, then checks every file's sha256.
    /// A fresh download that fails the check is deleted, and the command exits non-zero.
    func fetch() async throws {
        // Strip any Hugging Face token so the request carries no identity,
        // and any registry override so the host is always the Hub.
        for k in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN",
                  "REGISTRY_URL", "MODEL_REGISTRY_URL"] { unsetenv(k) }
        guard let pin else { throw CLIError("no pinned commit for \(repo.folderName) in the manifest; refusing to download") }
        ModelRegistry.baseURL = "https://huggingface.co"
        ModelRegistry.repoOverrides = [:]
        ModelRegistry.revisionOverrides = Dictionary(uniqueKeysWithValues: ModelManifest.pins.map { ($0.repo, $0.revision) })
        guard pin.repo == repo.remotePath else {
            throw CLIError("manifest pins \(pin.repo) for \(repo.folderName), but the library downloads \(repo.remotePath)")
        }

        try Paths.ensurePrivateDir(Paths.models)
        let wasPresent = isPresent
        try await AsrModels.download(to: directory, version: version)

        let problems = try verify()
        guard problems.isEmpty else {
            let list = problems.prefix(10).joined(separator: "\n  ")
            if wasPresent {
                throw CLIError("""
                    the model files in \(directory.path) do not match the manifest:
                      \(list)
                    Move that folder away, then run larynx models fetch again.
                    """)
            }
            try? FileManager.default.removeItem(at: directory)
            throw CLIError("""
                the download did not match the manifest, so it was deleted:
                  \(list)
                """)
        }
    }
}
