import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct GrokBotLiveActivityBundle: WidgetBundle {
    var body: some Widget { CallLiveActivity() }
}

/// A Grok Bot call outside the app (0.9.9): Dynamic Island and Lock Screen.
struct CallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CallActivityAttributes.self) { context in
            CallBanner(context: context)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    face(context, size: 46).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    CallTitle(context: context).frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CallButtons(muted: context.state.muted).padding(.trailing, 4)
                }
            } compactLeading: {
                face(context, size: 22)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit().font(.system(size: 14, weight: .medium))
                    .foregroundStyle(context.state.muted ? Color.red : Color.white)
                    .frame(maxWidth: 44).multilineTextAlignment(.trailing)
            } minimal: {
                face(context, size: 22)
            }
            .keylineTint(BotGlyph.color(context.attributes.color))
        }
    }

    private func face(_ context: ActivityViewContext<CallActivityAttributes>, size: CGFloat) -> some View {
        BotGlyphFace(shape: context.attributes.shape, color: context.attributes.color, size: size)
    }
}

/// Lock Screen and banner layout, matching the expanded Dynamic Island.
private struct CallBanner: View {
    let context: ActivityViewContext<CallActivityAttributes>
    var body: some View {
        HStack(spacing: 14) {
            BotGlyphFace(shape: context.attributes.shape, color: context.attributes.color, size: 46)
            CallTitle(context: context)
            Spacer(minLength: 8)
            CallButtons(muted: context.state.muted)
        }
    }
}

private struct CallTitle: View {
    let context: ActivityViewContext<CallActivityAttributes>
    private var detail: String {
        if context.state.muted { return "Muted" }
        switch context.state.phase {
        case "speaking": return "Speaking"
        case "thinking": return "Thinking"
        default: return context.attributes.botName
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit().font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            Text(detail).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Call with \(context.attributes.botName)")
    }
}

private struct CallButtons: View {
    let muted: Bool
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: ToggleCallMuteIntent()) {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(muted ? Color.black : Color.white)
                    .frame(width: 46, height: 46)
                    .background(muted ? Color.white : Color.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            Button(intent: EndCallIntent()) {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color(red: 0.95, green: 0.2, blue: 0.29), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
        }
    }
}
