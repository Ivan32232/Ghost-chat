import SwiftUI

/// Phase 7 typography system. Semantic helpers keep the chat surface off the default
/// `Font.body` / `Font.title` treadmill — rounded sans for headings, monospaced digits
/// for timers + safety numbers, crisp sans for message bubbles.
///
/// Mirror of the Android `Typography` object.
enum GhostType {
    /// Welcome screen + large titles. Rounded, semibold, 28pt.
    static let titleLarge: Font = .system(size: 28, weight: .semibold, design: .rounded)
    /// Section headers inside Settings / Contacts.
    static let titleMedium: Font = .system(size: 20, weight: .semibold, design: .rounded)
    /// Chat bubble body — regular sans, 15pt.
    static let bubbleBody: Font = .system(size: 15, weight: .regular, design: .default)
    /// Per-bubble timestamp / size label.
    static let bubbleCaption: Font = .system(size: 11, weight: .medium, design: .default)
    /// Call-duration timer / safety number / counters — monospaced digits.
    static let monoNumber: Font = .system(size: 16, weight: .medium, design: .monospaced)
    /// Inline system-note bubbles ("Peer took a screenshot" etc.).
    static let systemNote: Font = .system(size: 12, weight: .regular, design: .default)
}
