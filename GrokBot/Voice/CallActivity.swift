#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

/// A voice call that lives in the Dynamic Island and on the Lock Screen while you use other apps (0.9.9).
/// Compiled into both the app and the Live Activity extension.
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var startedAt: Date
        var muted: Bool
        /// "listening", "thinking" or "speaking".
        var phase: String
    }
    var botName: String
    /// `BotAvatarShape` raw value and color name, so the extension draws the same face.
    var shape: String
    var color: String
}

/// Hooks the app sets so Live Activity buttons reach the running call. Live Activity intents run in the
/// app's process, so these are set there; in the extension they stay nil and the buttons do nothing.
@MainActor
enum CallControl {
    static var toggleMute: (() -> Void)?
    static var end: (() -> Void)?
}

struct ToggleCallMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mute or unmute the call"
    static let isDiscoverable = false
    init() {}
    @MainActor
    func perform() async throws -> some IntentResult {
        CallControl.toggleMute?()
        return .result()
    }
}

struct EndCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End the call"
    static let isDiscoverable = false
    init() {}
    @MainActor
    func perform() async throws -> some IntentResult {
        CallControl.end?()
        return .result()
    }
}
#endif
