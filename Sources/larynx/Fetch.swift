import FluidAudio
import Foundation
import LarynxCore
import LarynxSpeech

typealias CLIError = SpeechError

extension SpeechModel {
    /// The ONLY network path in Larynx: fetch weights from Hugging Face. Sends no user data.
    /// It lives in the CLI, never in the app.
    func fetch() async throws {
        // Strip any Hugging Face token so the request carries no identity.
        for k in ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HUGGINGFACEHUB_API_TOKEN"] { unsetenv(k) }
        try Paths.ensurePrivateDir(Paths.models)
        try await AsrModels.download(to: directory, version: version)
    }
}
