import Foundation

@MainActor
enum WebHandoff {
    enum CopyResult: Equatable {
        case copied(characters: Int)
        case empty
        case copyFailed
    }

    static func payload(_ transcript: String) -> String? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ProofreadingPrompt.user(transcript)
    }

    static func copyPrompt(_ transcript: String, write: (String) -> Bool) -> CopyResult {
        guard let text = payload(transcript) else { return .empty }
        guard write(text) else { return .copyFailed }
        return .copied(characters: transcript.unicodeScalars.count)
    }

    /// NSWorkspace may invoke OpenURLAction's completion on a background queue.
    nonisolated static func onMainActor(
        _ update: @escaping @MainActor @Sendable (Bool) -> Void
    ) -> @Sendable (Bool) -> Void {
        { accepted in
            Task { @MainActor in update(accepted) }
        }
    }
}
