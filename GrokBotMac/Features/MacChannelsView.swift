import AppKit
import SwiftUI

/// Settings → Channels on the Mac (10.2). Pick the Bot that answers, set up Telegram or iMessage (through Inkbox), turn them on,
/// and let people in with the code the Bot sent them. Saved tokens are never shown again, only that they are set.
struct MacChannelsSettings: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var channels = MacChannels.shared
    @State private var open: Set<MacChannelKind> = []
    @State private var drafts: [String: String] = [:]
    @State private var codes: [String: String] = [:]
    @State private var message: String?

    private var bots: [Bot] { app.workspace.bots.filter { $0.memberIDs == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reach a Bot from the chat apps you already use. It answers people you approve, and it can message them for you when you ask.")
                .font(.system(size: 14)).lineSpacing(3).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Answers on channels").font(.system(size: 14.5, weight: .semibold))
                    Text("One Bot speaks for you everywhere. It is told which channels are on and can message approved people.")
                        .font(.system(size: 12.5)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("Bot that answers on channels", selection: Binding(get: { channels.data.bot }, set: { channels.setBot($0) })) {
                    Text("Choose a Bot…").tag(UUID?.none)
                    ForEach(bots) { bot in Text(bot.name).tag(UUID?.some(bot.id)) }
                }.labelsHidden().frame(width: 200)
            }
            .macCard()
            ForEach(MacChannelKind.allCases) { kind in card(kind) }
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(MacTheme.attention).transition(.opacity)
            }
            Text("Discord, Slack, SMS and phone calls are available in the Windows app and on a Bothive Docker server. Strangers who message your Bot get a 6-digit code and nothing else; ask them for it and enter it here to let them in. Tokens are kept in the Keychain on this Mac.")
                .font(.system(size: 12)).foregroundStyle(MacTheme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: open)
    }

    private func tone(_ kind: MacChannelKind) -> Color {
        guard channels.configured(kind), channels.config(kind).enabled else { return MacTheme.secondary }
        switch channels.state(kind) {
        case .on: return Color(hex: 0x30D158)
        case .failed: return MacTheme.danger
        case .starting: return MacTheme.attention
        case .off: return MacTheme.secondary
        }
    }
    private func label(_ kind: MacChannelKind) -> String {
        if !channels.configured(kind) { return "Not set up" }
        if !channels.config(kind).enabled { return "Off" }
        return channels.state(kind).label
    }

    @ViewBuilder private func card(_ kind: MacChannelKind) -> some View {
        let color = tone(kind), isOpen = open.contains(kind)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: kind == .telegram ? "paperplane.fill" : "message.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color(hex: kind == .telegram ? 0x2AABEE : 0x34C759), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(kind.name).font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(label(kind)).lineLimit(1) }
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
                            .padding(.horizontal, 8).padding(.vertical, 2.5).background(color.opacity(0.14), in: Capsule())
                    }
                    Text(kind.blurb).font(.system(size: 12.5)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                MacPillButton(title: isOpen ? "Done" : channels.configured(kind) ? "Manage" : "Set up", small: true) {
                    if isOpen { open.remove(kind) } else { open.insert(kind) }
                }
                Toggle("Turn \(kind.name) on", isOn: Binding(get: { channels.config(kind).enabled }, set: { on in run { try channels.setEnabled(kind, on) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!channels.configured(kind) || channels.data.bot == nil)
                    .help(!channels.configured(kind) ? "Set it up first" : channels.data.bot == nil ? "Choose which Bot answers first" : "")
            }
            .padding(14)
            ForEach(channels.pending(kind)) { person in pendingRow(kind, person) }
            if isOpen { details(kind).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .background(MacTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(channels.config(kind).enabled ? color.opacity(0.32) : MacTheme.line, lineWidth: 1))
    }

    private func pendingRow(_ kind: MacChannelKind, _ person: MacChannelPending) -> some View {
        HStack(spacing: 12) {
            Text(String(person.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.attention)
                .frame(width: 30, height: 30).background(MacTheme.attention.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(person.name) wants to talk").font(.system(size: 13.5, weight: .medium))
                Text("Ask them for the code the Bot sent").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            }
            Spacer(minLength: 8)
            TextField("6-digit code", text: Binding(get: { codes[kind.rawValue + person.senderID] ?? "" }, set: { codes[kind.rawValue + person.senderID] = String($0.filter(\.isNumber).prefix(6)) }))
                .textFieldStyle(.roundedBorder).frame(width: 110).font(.system(size: 13, design: .monospaced))
                .accessibilityLabel("Code from \(person.name)")
                .onSubmit { approve(kind, person) }
            MacPillButton(title: "Approve", prominent: true, small: true) { approve(kind, person) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(MacTheme.attention.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MacTheme.attention.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func details(_ kind: MacChannelKind) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(kind.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MacTheme.tertiary)
                        Text(step).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(kind.fields) { field in
                HStack(spacing: 12) {
                    Text(field.label).font(.system(size: 13)).frame(width: 130, alignment: .leading)
                    let saved = channels.config(kind).fields[field.key] != nil
                    let binding = Binding(get: { drafts[kind.rawValue + field.key] ?? "" }, set: { drafts[kind.rawValue + field.key] = $0 })
                    Group {
                        if field.secret { SecureField(saved ? "Saved · type to replace" : field.placeholder, text: binding) }
                        else { TextField(field.placeholder, text: binding) }
                    }.textFieldStyle(.roundedBorder).accessibilityLabel(field.label)
                }
            }
            HStack(spacing: 8) {
                MacPillButton(title: "Save", prominent: true, small: true) { save(kind) }
                MacPillButton(title: "Open the guide ↗", small: true) { NSWorkspace.shared.open(kind.guide) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("APPROVED PEOPLE").font(.system(size: 11, weight: .semibold)).kerning(0.5).foregroundStyle(MacTheme.tertiary)
                if channels.approved(kind).isEmpty {
                    Text("Nobody yet. Message the Bot from your own account to get a code, then enter it above.").font(.system(size: 12.5)).foregroundStyle(MacTheme.secondary)
                }
                ForEach(channels.approved(kind)) { person in
                    HStack(spacing: 12) {
                        Text(String(person.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.working)
                            .frame(width: 30, height: 30).background(MacTheme.working.opacity(0.16), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name).font(.system(size: 13.5, weight: .medium))
                            Text("Approved \(person.at.formatted(.relative(presentation: .named)))").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { channels.remove(kind, person: person.id) }.buttonStyle(.borderless).foregroundStyle(MacTheme.danger)
                    }
                }
            }
        }
        .padding(.leading, 64).padding(.trailing, 14).padding(.bottom, 16)
    }

    private func save(_ kind: MacChannelKind) {
        var fields: [String: String] = [:]
        for field in kind.fields { let value = drafts[kind.rawValue + field.key] ?? ""; if !value.isEmpty || !field.secret { fields[field.key] = value }; drafts[kind.rawValue + field.key] = nil }
        run { try channels.configure(kind, fields: fields); message = "\(kind.name) saved." }
    }

    private func approve(_ kind: MacChannelKind, _ person: MacChannelPending) {
        run { let name = try channels.approve(kind, code: codes[kind.rawValue + person.senderID] ?? ""); message = "\(name) can talk to the Bot now." }
    }

    private func run(_ work: () throws -> Void) {
        do { message = nil; try work() } catch { message = error.localizedDescription }
    }
}
