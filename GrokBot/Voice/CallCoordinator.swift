#if os(iOS)
import ActivityKit
import AVFoundation
import CallKit
import Foundation

/// Lets a voice call keep going outside the app (0.9.9). iOS treats it as a VoIP call through CallKit, and a
/// Live Activity shows the Bot, a timer, mute and end in the Dynamic Island and on the Lock Screen.
///
/// If CallKit refuses the call (the Simulator, or a region where CallKit is unavailable), the call still runs
/// with the Live Activity alone. `VoiceSession` keeps managing its own audio session in both cases.
@MainActor
final class CallCoordinator: NSObject, CXProviderDelegate {
    static let shared = CallCoordinator()

    /// Called when mute changes from outside the app's own button (system call UI or the Live Activity).
    var onMute: ((Bool) -> Void)?
    /// Called when the call is ended from outside the app (system call UI, the Live Activity, another call).
    var onEnd: (() -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var callID: UUID?
    private var callKitActive = false
    private var activity: Activity<CallActivityAttributes>?
    private var state = CallActivityAttributes.ContentState(startedAt: .now, muted: false, phase: "listening")

    var isMuted: Bool { state.muted }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        // Tapping a Recents entry would try to redial a Bot through an intent this app doesn't handle.
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
        // A crash or force-quit can leave an old call's activity on the Lock Screen.
        Task {
            for stale in Activity<CallActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: From the app

    func begin(botName: String, shape: String, color: String) {
        guard callID == nil else { return }
        let id = UUID()
        callID = id
        state = .init(startedAt: .now, muted: false, phase: "listening")
        startActivity(CallActivityAttributes(botName: botName, shape: shape, color: color))

        let handle = CXHandle(type: .generic, value: botName)
        let action = CXStartCallAction(call: id, handle: handle)
        action.contactIdentifier = botName
        controller.request(CXTransaction(action: action)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                // Keep the call with the Live Activity alone.
                if self?.callID == id { self?.callKitActive = false }
                print("CallKit declined the call; using the Live Activity only:", error.localizedDescription)
            }
        }
    }

    /// Mute from the app or the Live Activity. Goes through CallKit when it owns the call so the system UI agrees.
    func requestMute(_ on: Bool) {
        guard let id = callID else { return }
        if callKitActive {
            controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: on))) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.applyMute(on) }
            }
        } else {
            applyMute(on)
        }
    }

    func update(phase: String) {
        guard callID != nil, state.phase != phase else { return }
        state.phase = phase
        pushState()
    }

    /// Ends the call from the app. Safe to call more than once.
    func end() {
        guard let id = callID else { return }
        callID = nil
        if callKitActive {
            callKitActive = false
            controller.request(CXTransaction(action: CXEndCallAction(call: id))) { _ in }
        }
        endActivity()
    }

    // MARK: CXProviderDelegate (delivered on the main queue)

    // Only Sendable values (UUIDs, Bools) cross into main-actor code; the CXAction objects stay here.

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { self.endedOutside() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let id = action.callUUID
        let ours = MainActor.assumeIsolated { self.acceptStart(id) }
        guard ours else { action.fail(); return }
        provider.reportOutgoingCall(with: id, startedConnectingAt: nil)
        action.fulfill()
        let update = CXCallUpdate()
        update.remoteHandle = action.handle
        update.localizedCallerName = action.contactIdentifier
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportCall(with: id, updated: update)
        provider.reportOutgoingCall(with: id, connectedAt: .now)
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let id = action.callUUID
        // The app already cleared callID when it ended the call itself.
        MainActor.assumeIsolated { if id == self.callID { self.endedOutside() } }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let id = action.callUUID, muted = action.isMuted
        MainActor.assumeIsolated { if id == self.callID { self.applyMute(muted) } }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

    // MARK: Private

    private func acceptStart(_ id: UUID) -> Bool {
        guard id == callID else { return false }
        callKitActive = true
        return true
    }

    private func applyMute(_ on: Bool) {
        guard state.muted != on else { return }
        state.muted = on
        onMute?(on)
        pushState()
    }

    private func endedOutside() {
        guard callID != nil else { return }
        callID = nil
        callKitActive = false
        endActivity()
        onEnd?()
    }

    private func startActivity(_ attributes: CallActivityAttributes) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        } catch {
            print("The call's Live Activity could not start:", error.localizedDescription)
        }
    }

    private func pushState() {
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
}
#endif
