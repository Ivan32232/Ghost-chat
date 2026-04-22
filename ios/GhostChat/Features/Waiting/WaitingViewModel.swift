import Foundation
import UIKit

/// Thin view model for `WaitingView`: formats the invite URL, publishes a
/// transient "copied" flag for the copy button, and defers all real
/// side-effects to the injected `ConnectionManager`.
///
/// Design: no Combine subscriptions — state transitions are observed by the
/// view directly via `@EnvironmentObject`. This VM only exposes commands and
/// helpers that are easy to unit-test without SwiftUI.
@MainActor
final class WaitingViewModel: ObservableObject {
    static let inviteBaseURL = URL(string: "https://ghostchat.one/")!

    @Published private(set) var copiedFeedbackVisible: Bool = false

    /// Injected during tests so we can observe pasteboard writes without
    /// poking UIKit globals.
    private let pasteboardWrite: (String) -> Void

    init(pasteboardWrite: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
        self.pasteboardWrite = pasteboardWrite
    }

    /// Build the invite URL we paste into share sheets and clipboards.
    /// Uses query form (`?room=<id>`) so it also works as a plain web link
    /// and as the universal-link shape configured in entitlements.
    func shareURL(roomId: String) -> URL {
        var comps = URLComponents(url: Self.inviteBaseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "room", value: roomId)]
        return comps.url!
    }

    /// Truncated display label, e.g. `"rBwU4hZ6…8VvG"`. Anything under 12 chars
    /// renders in full — no point eliding already-short ids.
    func displayID(_ roomId: String) -> String {
        guard roomId.count > 12 else { return roomId }
        let head = roomId.prefix(8)
        let tail = roomId.suffix(4)
        return "\(head)…\(tail)"
    }

    /// Copies the invite URL to the system clipboard and flashes the UI hint
    /// for ~2 seconds.
    func copy(roomId: String) {
        pasteboardWrite(shareURL(roomId: roomId).absoluteString)
        copiedFeedbackVisible = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { self.copiedFeedbackVisible = false }
        }
    }

    /// Test hook: synchronously set the copied flag without the async delay.
    func _test_markCopied() {
        copiedFeedbackVisible = true
    }
}
