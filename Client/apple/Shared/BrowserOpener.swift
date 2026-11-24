import Foundation

enum BrowserOpener {
    /// Start the UI action on MainActor, but accept its result from any queue.
    @MainActor
    static func open(_ url: URL,
                     using action: @MainActor (URL, @escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            // LaunchServices can call this on its background open-queue. Only
            // resume the Sendable continuation here; the awaiting task keeps
            // its original actor before touching any view state.
            action(url) { @Sendable accepted in
                continuation.resume(returning: accepted)
            }
        }
    }
}
