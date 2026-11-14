import AppKit
import Combine
import SwiftUI

/// A voice call outside the window (0.9.9): a black pill at the top of the screen that grows out of the notch,
/// shown while a call is on and you're in another app. Hover to expand it for mute and end; click the Bot's
/// face to come back. On Macs without a notch it floats just below the menu bar.
@MainActor
final class MacCallPill {
    static let shared = MacCallPill()

    private var panel: NSPanel?
    private let state = MacCallPillState()
    private var watchers: [AnyCancellable] = []
    private weak var hub: MacVoiceHub?
    private var collapseTask: Task<Void, Never>?

    /// Start following a call. The pill appears whenever the app isn't in front.
    func attach(hub: MacVoiceHub, bot: Bot) {
        detach()
        self.hub = hub
        let look = bot.appearance ?? BotAppearance(shape: bot.isMain == true ? .circle : .square, color: bot.color)
        state.botName = bot.name
        state.shape = look.shape.rawValue
        state.color = look.color
        state.startedAt = .now
        state.expanded = false
        let center = NotificationCenter.default
        watchers = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSApplication.didChangeScreenParametersNotification,
        ].map { name in
            center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    func detach() {
        watchers = []
        collapseTask?.cancel()
        hub = nil
        panel?.orderOut(nil)
    }

    // MARK: Showing and placing

    private var mainWindowShowing: Bool {
        NSApp.windows.contains { $0 !== panel && $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
    }

    private func refresh() {
        guard let hub, hub.isOn else { panel?.orderOut(nil); return }
        if NSApp.isActive && mainWindowShowing {
            panel?.orderOut(nil)
            state.expanded = false
            return
        }
        let panel = self.panel ?? makePanel(session: hub.conversation.session)
        self.panel = panel
        place(panel, expanded: state.expanded)
        panel.orderFrontRegardless()
    }

    private func makePanel(session: VoiceSession) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar so the pill can sit in the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        let view = MacCallPillView(
            state: state, session: session,
            hover: { [weak self] inside in self?.hover(inside) },
            open: { [weak self] in self?.openApp() },
            mute: { session.setMuted(!session.muted) },
            end: { [weak self] in self?.hub?.stop() })
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    private func place(_ panel: NSPanel, expanded: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let geometry = MacCallPillGeometry(screen: screen)
        state.notch = geometry.notchWidth
        state.barHeight = geometry.barHeight
        let size = geometry.size(expanded: expanded)
        let top = geometry.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 6
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Interaction

    /// Grow the window first so the pill can animate into it; shrink it after the pill has animated back.
    private func hover(_ inside: Bool) {
        guard let panel else { return }
        collapseTask?.cancel()
        if inside {
            place(panel, expanded: true)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { state.expanded = true }
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { state.expanded = false }
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, let panel = self.panel, !self.state.expanded else { return }
                self.place(panel, expanded: false)
            }
        }
    }

    private func openApp() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0 !== panel && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class MacCallPillState: ObservableObject {
    @Published var expanded = false
    @Published var botName = ""
    @Published var shape = "circle"
    @Published var color = "white"
    @Published var startedAt = Date.now
    @Published var notch: CGFloat = 0
    @Published var barHeight: CGFloat = 32
}

/// Sizes for the pill on a given screen.
struct MacCallPillGeometry {
    let notchWidth: CGFloat
    let barHeight: CGFloat
    var hasNotch: Bool { notchWidth > 0 }
    static let wing: CGFloat = 54

    @MainActor
    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
            barHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            barHeight = 36
        }
    }

    func size(expanded: Bool) -> CGSize { Self.size(notch: notchWidth, bar: barHeight, expanded: expanded) }

    static func size(notch: CGFloat, bar: CGFloat, expanded: Bool) -> CGSize {
        if notch > 0 {
            let collapsed = notch + wing * 2
            return expanded ? CGSize(width: max(collapsed + 40, 380), height: bar + 70) : CGSize(width: collapsed, height: bar)
        }
        return expanded ? CGSize(width: 360, height: 70) : CGSize(width: 132, height: bar)
    }
}

struct MacCallPillView: View {
    @ObservedObject var state: MacCallPillState
    @ObservedObject var session: VoiceSession
    let hover: (Bool) -> Void
    let open: () -> Void
    let mute: () -> Void
    let end: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGSize { MacCallPillGeometry.size(notch: state.notch, bar: state.barHeight, expanded: state.expanded) }
    private var shape: AnyShape {
        if state.notch > 0 {
            let radius: CGFloat = state.expanded ? 26 : 12
            return AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
        }
        return AnyShape(RoundedRectangle(cornerRadius: size.height / 2, style: .continuous))
    }
    private var detail: String {
        if session.muted { return "Muted" }
        switch session.state {
        case .speaking: return "Speaking"
        case .thinking: return "Thinking"
        default: return state.botName
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape.fill(Color.black)
                if state.expanded { expanded.transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top))) }
                else { compact.transition(.opacity) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .contentShape(shape)
            .onHover(perform: hover)
            .environment(\.colorScheme, .dark)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8), value: state.expanded)
    }

    private var face: some View {
        Button(action: open) {
            BotGlyphFace(shape: state.shape, color: state.color, size: state.expanded ? 40 : 20)
        }
        .buttonStyle(.plain)
        .help("Open \(state.botName)")
        .accessibilityLabel("Open \(state.botName)")
    }

    private var timer: some View {
        Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .foregroundStyle(session.muted ? Color(red: 1, green: 0.35, blue: 0.4) : .white)
    }

    private var compact: some View {
        HStack(spacing: 0) {
            face
            Spacer(minLength: state.notch)
            timer.font(.system(size: 13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .frame(height: state.barHeight)
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            if state.notch > 0 { Color.clear.frame(height: state.barHeight - 4) }
            HStack(spacing: 12) {
                face
                VStack(alignment: .leading, spacing: 1) {
                    timer.font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: mute) {
                    Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(session.muted ? Color.black : Color.white)
                        .frame(width: 38, height: 38)
                        .background(session.muted ? Color.white : Color.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain).help(session.muted ? "Unmute" : "Mute")
                .accessibilityLabel(session.muted ? "Unmute" : "Mute")
                Button(action: end) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color(red: 0.95, green: 0.2, blue: 0.29), in: Circle())
                }
                .buttonStyle(.plain).help("End call").accessibilityLabel("End call")
            }
            .padding(.horizontal, 16)
            .frame(height: 70)
        }
    }
}
