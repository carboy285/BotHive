import SwiftUI

/// Chat channels of the server being viewed (10.1.2). One Bot you choose answers Telegram, Discord, Slack, iMessage (through Inkbox) and SMS,
/// and can phone you. The channels run on that server, not on this Mac. Tokens are sent to it and never come back: only whether each is set.
struct MacChannelsSection: View {
    let channels: RemoteChannels
    let serverName: String
    let canChange: Bool
    let reload: () async -> Void
    /// Runs one channels command and returns an error message, or nil when it worked. A server's channels and this Mac's use the same screen.
    let execute: (String, String?, String?, [String: String]?) async -> String?
    /// Shown under the intro when some channels cannot run here.
    var footnote: String? = nil
    @State private var drafts: [String: String] = [:]
    @State private var meDrafts: [String: Bool] = [:]
    @State private var open: Set<String> = []
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var feedback: String?
    @State private var busy = false

    private struct Field: Identifiable { var key: String; var label: String; var secret = false; var id: String { key } }
    private struct Spec: Identifiable {
        var id: String; var title: String; var steps: [String]; var fields: [Field]; var calls: [Field] = []
    }
    private let specs: [Spec] = [
        Spec(id: "telegram", title: "Telegram", steps: ["In Telegram, message @BotFather and send /newbot.", "Follow the steps, then paste the token it gives you.", "Message your new bot. It answers direct messages only."], fields: [Field(key: "token", label: "Bot token", secret: true)]),
        Spec(id: "discord", title: "Discord", steps: ["At discord.com/developers/applications make an application, then add a Bot.", "Under Bot, turn on Message Content Intent, then copy the token.", "Add it to a server with OAuth2 \u{2192} URL Generator (scope bot). It answers direct messages, and in a server when you @mention it."], fields: [Field(key: "token", label: "Bot token", secret: true)]),
        Spec(id: "slack", title: "Slack", steps: ["At api.slack.com/apps make an app from scratch and turn on Socket Mode.", "Make an App-Level Token with connections:write (starts xapp-).", "Under OAuth & Permissions add chat:write, im:history, im:read, files:read (so pictures reach the Bot) and app_mentions:read, install it and copy the Bot token (starts xoxb-).", "Under Event Subscriptions turn on message.im and app_mention."], fields: [Field(key: "botToken", label: "Bot token (xoxb-)", secret: true), Field(key: "appToken", label: "App-level token (xapp-)", secret: true)]),
        Spec(id: "imessage", title: "iMessage (through Inkbox)", steps: ["Sign up at inkbox.ai and create an agent with iMessage turned on.", "Make an API key for that agent in the Inkbox console and paste it here.", "From your phone, text \u{201C}connect @your-agent-handle\u{201D} to Inkbox\u{2019}s router number (the console shows it). After that, your messages reach the Bot.", "Inkbox limits an agent to about 100 iMessages a day on the base plan."], fields: [Field(key: "apiKey", label: "Inkbox API key", secret: true)], calls: [Field(key: "ownerNumber", label: "Your phone number for calls (+15551234567)")]),
        Spec(id: "sms", title: "SMS and phone calls (Twilio)", steps: ["Make a Twilio account and buy a phone number.", "Paste its Account SID, Auth Token and number. Texts to that number reach the Bot.", "For calls, add your own number, a PIN and a public https address. On the server run \u{201C}tailscale funnel --bg 8766\u{201D} and paste the address it prints. Only the phone port is public.", "The Bot calls you, or you call the number and enter the PIN. Say \u{201C}call me\u{201D} in any channel to get a call."],
             fields: [Field(key: "accountSid", label: "Account SID"), Field(key: "authToken", label: "Auth Token", secret: true), Field(key: "number", label: "Twilio number (+15551234567)")],
             calls: [Field(key: "ownerNumber", label: "Your own number (+15551234567)"), Field(key: "pin", label: "Call PIN (4 to 8 digits)", secret: true), Field(key: "publicUrl", label: "Public https address"), Field(key: "language", label: "Call language (en-US)")]),
    ]

    private var settings: RemoteChannels.Settings { channels.settings ?? RemoteChannels.Settings() }
    private func setting(_ fields: [String: String]) { run("channels_set_settings", fields: fields, done: "Saved.") }

    private static let look: [String: (symbol: String, color: UInt32, blurb: String)] = [
        "telegram": ("paperplane.fill", 0x2AABEE, "Direct messages to a Telegram bot you make in a minute with @BotFather."),
        "discord": ("gamecontroller.fill", 0x5865F2, "Direct messages to a Discord bot, and in a server when someone mentions it."),
        "slack": ("number", 0xE01E5A, "Direct messages and @mentions in a Slack workspace."),
        "imessage": ("message.fill", 0x34C759, "Your Bot gets its own iMessage identity through Inkbox, so people text it like a contact. It can also phone you."),
        "sms": ("message", 0x34C759, "Texts and phone calls through a Twilio number. Runs on a Bothive server."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reach a Bot from the chat apps you already use. It answers people you approve, and it can message or phone you when you need to know something.")
                .font(.system(size: 14)).lineSpacing(3).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
            if let footnote { Text(footnote).font(.system(size: 12.5)).lineSpacing(3).foregroundStyle(MacTheme.tertiary).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Answers on channels").font(.system(size: 14.5, weight: .semibold))
                    Text("One Bot speaks for you everywhere on \(serverName). It is told which channels are on and can message approved people.")
                        .font(.system(size: 12.5)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("Bot that answers", selection: Binding(get: { channels.bot ?? "" }, set: { value in run("channels_set_bot", text: value, done: value.isEmpty ? "No Bot answers on channels." : "That Bot now answers on your channels.") })) {
                    Text("Choose a Bot\u{2026}").tag("")
                    ForEach(channels.bots) { Text($0.name).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 200).disabled(!canChange)
            }
            .macCard()
            behaviour
            if let feedback { Text(feedback).font(.system(size: 13)).foregroundStyle(MacTheme.attention).fixedSize(horizontal: false, vertical: true) }
            ForEach(specs) { spec in if let info = channels.channels[spec.id] { channelCard(spec, info) } }
            Text("Strangers who message your Bot get a short code and nothing else. Tokens are sent to the computer that runs the Bot and are never shown again.")
                .font(.system(size: 12)).foregroundStyle(MacTheme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: open)
    }

    /// How the Bot behaves on channels: speed, steering, where replies go and when it reaches out.
    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Fast replies on channels (a quicker model, short answers)", isOn: Binding(get: { settings.fast }, set: { value in setting(["fast": value ? "true" : "false"]) })).font(.system(size: 14)).disabled(!canChange)
            row("When I send another message while the Bot is working", "When I send while it is working", Binding(get: { settings.whenBusy }, set: { setting(["whenBusy": $0]) }),
                [("steer", "Steer it: stop and carry on with my new message"), ("queue", "Queue it: answer after the current one")])
            row("Where replies go", "Where replies go", Binding(get: { settings.replies ?? "where" }, set: { setting(["replies": $0]) }),
                [("where", "Reply where I wrote (scheduled tasks text me)"), ("always", "Always text me too")])
            row("When the Bot needs me and I have not messaged it, reach me on", "Reach me on", Binding(get: { settings.reachOn ?? "" }, set: { setting(["reachOn": $0]) }),
                [("", "Any channel where I am marked Me")] + specs.map { ($0.id, $0.title) })
            row("If an urgent question gets no answer", "If I do not answer", Binding(get: { settings.escalate }, set: { setting(["escalate": $0]) }),
                [("call", "Call me (outside quiet hours)"), ("text", "Text me again"), ("none", "Do nothing")])
            Text("Messages sent a second apart are read together, so a photo and \u{201C}add these to my reminders\u{201D} arrive as one request. Texting \u{201C}stop\u{201D} only stops the Bot.")
                .font(.system(size: 12)).lineSpacing(3).foregroundStyle(MacTheme.secondary)
        }
        .macCard()
    }

    private func row(_ title: String, _ label: String, _ selection: Binding<String>, _ options: [(String, String)]) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Picker(label, selection: selection) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }
                .labelsHidden().pickerStyle(.menu).fixedSize().disabled(!canChange)
        }
    }

    private func tone(_ info: RemoteChannels.Channel) -> Color {
        guard info.configured, info.enabled else { return MacTheme.secondary }
        switch info.state.state { case "on": return Color(hex: 0x30D158); case "error": return MacTheme.danger; default: return MacTheme.attention }
    }
    private func label(_ info: RemoteChannels.Channel) -> String {
        if !info.configured { return "Not set up" }
        guard info.enabled else { return "Off" }
        let detail = info.state.detail ?? ""
        switch info.state.state { case "on": return detail.isEmpty ? "On" : "On \u{00B7} \(detail)"; case "error": return detail.isEmpty ? "Not working" : "Not working \u{00B7} \(detail)"; default: return "Connecting\u{2026}" }
    }

    @ViewBuilder private func channelCard(_ spec: Spec, _ info: RemoteChannels.Channel) -> some View {
        let color = tone(info), isOpen = open.contains(spec.id), look = Self.look[spec.id]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: look?.symbol ?? "bubble.left.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Color(hex: look?.color ?? 0x8E8E93), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(spec.title).font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(label(info)).lineLimit(1) }
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
                            .padding(.horizontal, 8).padding(.vertical, 2.5).background(color.opacity(0.14), in: Capsule())
                    }
                    Text(look?.blurb ?? "").font(.system(size: 12.5)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                MacPillButton(title: isOpen ? "Done" : info.configured ? "Manage" : "Set up", small: true) { if isOpen { open.remove(spec.id) } else { open.insert(spec.id) } }
                Toggle("Turn \(spec.title) on", isOn: Binding(get: { info.enabled }, set: { on in run("channels_enable", channel: spec.id, text: on ? "on" : "off", done: on ? "\(spec.title) is on." : "\(spec.title) is off.") }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!canChange || busy || !info.configured || channels.bot == nil)
                    .help(!info.configured ? "Set it up first" : channels.bot == nil ? "Choose which Bot answers first" : "")
            }
            .padding(14)
            ForEach(info.pending) { person in pendingRow(spec, person) }
            if isOpen { details(spec, info).transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .background(MacTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(info.enabled ? color.opacity(0.32) : MacTheme.line, lineWidth: 1))
    }

    private func pendingRow(_ spec: Spec, _ person: RemoteChannels.Waiting) -> some View {
        HStack(spacing: 12) {
            Text(String(person.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.attention)
                .frame(width: 30, height: 30).background(MacTheme.attention.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("\(person.name) wants to talk").font(.system(size: 13.5, weight: .medium))
                Text("Code \(person.code) \u{00B7} approve only people you know").font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            }
            Spacer(minLength: 8)
            Toggle("This is me", isOn: Binding(get: { meDrafts[person.code] ?? false }, set: { meDrafts[person.code] = $0 })).font(.system(size: 12)).toggleStyle(.checkbox)
            MacPillButton(title: "Approve", prominent: true, small: true) {
                run("channels_approve", channel: spec.id, text: person.code, fields: (meDrafts[person.code] ?? false) ? ["me": "true"] : nil, done: "\(person.name) can now message the Bot.")
            }.disabled(!canChange || busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(MacTheme.attention.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MacTheme.attention.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func details(_ spec: Spec, _ info: RemoteChannels.Channel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(spec.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MacTheme.tertiary)
                        Text(step).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(spec.fields) { field(spec.id, $0, info) }
            if !spec.calls.isEmpty {
                Text("PHONE CALLS").font(.system(size: 11, weight: .semibold)).kerning(0.5).foregroundStyle(MacTheme.tertiary)
                ForEach(spec.calls) { field(spec.id, $0, info) }
            }
            HStack(spacing: 8) {
                MacPillButton(title: "Save", prominent: true, small: true) { save(spec, info) }.disabled(!canChange || busy)
                if spec.id == "sms" || spec.id == "imessage" { MacPillButton(title: "Call me now", small: true) { run("channels_test_call", done: "Calling you now.") }.disabled(!canChange || busy) }
            }
            if spec.id == "imessage", info.enabled, let inkbox = channels.inkbox {
                HStack {
                    Text("Phone voice").font(.system(size: 13))
                    Spacer()
                    Picker("Phone voice", selection: Binding(get: { info.fields["voice"]?.text ?? "" }, set: { value in run("channels_configure", channel: "imessage", fields: ["voice": value], done: "Voice saved.") })) {
                        Text("Default voice").tag("")
                        ForEach(inkbox.voices) { Text($0.name + ($0.available ? "" : " (unavailable)")).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(!canChange)
                }
                Text("Calls are answered by Inkbox\u{2019}s voice assistant, which is told your Bot\u{2019}s name, style and notes. It cannot run the Bot\u{2019}s tools during a call; the transcript comes back into the Bot\u{2019}s chat and anything left to do is handed to the Bot. Tip: in the Inkbox console set the agent to contact-scoped access and allow only your own number to call it.")
                    .font(.system(size: 12)).lineSpacing(3).foregroundStyle(MacTheme.secondary)
                if inkbox.state?.state == "error", let detail = inkbox.state?.detail, !detail.isEmpty { Text("Phone calls: \(detail)").font(.system(size: 12)).foregroundStyle(MacTheme.attention) }
                if let question = inkbox.pendingAsk?.question { Text("The Bot is waiting for your answer to: \(question)").font(.system(size: 12)).foregroundStyle(MacTheme.secondary) }
            }
            if spec.id == "sms" {
                Text(channels.calls.ready ? (channels.calls.listening ? "Calls are ready. Twilio reaches the phone port at your public address." : "Calls are set up and starting.") : "Calls need your Twilio number, your own number and an https address.")
                    .font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("APPROVED PEOPLE").font(.system(size: 11, weight: .semibold)).kerning(0.5).foregroundStyle(MacTheme.tertiary)
                if info.approved.isEmpty { Text("Nobody yet. Message the Bot from your own account to get a code, then approve it above.").font(.system(size: 12.5)).foregroundStyle(MacTheme.secondary) }
                ForEach(info.approved) { person in
                    HStack(spacing: 12) {
                        Text(String(person.name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.working)
                            .frame(width: 30, height: 30).background(MacTheme.working.opacity(0.16), in: Circle())
                        if renaming == spec.id + ":" + person.id {
                            TextField("Name", text: $renameText).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                            MacPillButton(title: "Save", small: true) { run("channels_set_person", channel: spec.id, text: person.id, fields: ["name": renameText], done: "Saved.") { renaming = nil } }.disabled(!canChange || busy)
                        } else {
                            Text(person.name == person.id ? person.id : "\(person.name) \u{00B7} \(person.id)").font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                        }
                        Spacer()
                        Toggle("Me", isOn: Binding(get: { person.me == true }, set: { value in run("channels_set_person", channel: spec.id, text: person.id, fields: ["me": value ? "true" : "false"], done: value ? "The Bot can now reach out to this person first." : "Saved.") }))
                            .font(.system(size: 12)).toggleStyle(.checkbox).disabled(!canChange || busy)
                        Button("Rename") { renameText = person.name == person.id ? "" : person.name; renaming = spec.id + ":" + person.id }.buttonStyle(.borderless).disabled(!canChange || busy)
                        Button("Remove", role: .destructive) { run("channels_remove", channel: spec.id, text: person.id, done: "Removed \(person.name).") }.buttonStyle(.borderless).foregroundStyle(MacTheme.danger).disabled(!canChange || busy)
                    }
                }
            }
        }
        .padding(.leading, 64).padding(.trailing, 14).padding(.bottom, 16)
    }

    @ViewBuilder private func field(_ channel: String, _ item: Field, _ info: RemoteChannels.Channel) -> some View {
        let key = channel + "." + item.key
        let saved = info.fields[item.key]
        VStack(alignment: .leading, spacing: 4) {
            Text(item.label).font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            if item.secret {
                SecureField(saved?.set == true ? "Saved \u{2014} type to replace" : "", text: Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })).textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: Binding(get: { drafts[key] ?? saved?.text ?? "" }, set: { drafts[key] = $0 })).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            }
        }.frame(maxWidth: 440, alignment: .leading)
    }

    private func save(_ spec: Spec, _ info: RemoteChannels.Channel) {
        var values: [String: String] = [:]
        for item in spec.fields + spec.calls {
            let key = spec.id + "." + item.key
            if item.secret { if let value = drafts[key], !value.isEmpty { values[item.key] = value } }
            else { values[item.key] = drafts[key] ?? info.fields[item.key]?.text ?? "" }
        }
        run("channels_configure", channel: spec.id, fields: values, done: "Saved \(spec.title).") {
            for item in spec.fields + spec.calls where item.secret { drafts[spec.id + "." + item.key] = nil }
        }
    }

    private func run(_ action: String, channel: String? = nil, text: String? = nil, fields: [String: String]? = nil, done: String, after: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; feedback = nil
        Task {
            if let problem = await execute(action, channel, text, fields) { feedback = problem } else { after?(); feedback = done }
            await reload()
            busy = false
        }
    }
}
