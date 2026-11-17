import SwiftUI

/// Chat channels of the server being viewed (10.1.2). One Bot you choose answers Telegram, Discord, Slack, iMessage (through Inkbox) and SMS,
/// and can phone you. The channels run on that server, not on this Mac. Tokens are sent to it and never come back: only whether each is set.
struct MacChannelsSection: View {
    let channels: RemoteChannels
    let serverName: String
    let canChange: Bool
    let reload: () async -> Void
    @EnvironmentObject private var desktop: MacAppModel
    @State private var drafts: [String: String] = [:]
    @State private var feedback: String?
    @State private var busy = false

    private struct Field: Identifiable { var key: String; var label: String; var secret = false; var id: String { key } }
    private struct Spec: Identifiable {
        var id: String; var title: String; var steps: [String]; var fields: [Field]; var calls: [Field] = []
    }
    private let specs: [Spec] = [
        Spec(id: "telegram", title: "Telegram", steps: ["In Telegram, message @BotFather and send /newbot.", "Follow the steps, then paste the token it gives you.", "Message your new bot. It answers direct messages only."], fields: [Field(key: "token", label: "Bot token", secret: true)]),
        Spec(id: "discord", title: "Discord", steps: ["At discord.com/developers/applications make an application, then add a Bot.", "Under Bot, turn on Message Content Intent, then copy the token.", "Add it to a server with OAuth2 \u{2192} URL Generator (scope bot). It answers direct messages, and in a server when you @mention it."], fields: [Field(key: "token", label: "Bot token", secret: true)]),
        Spec(id: "slack", title: "Slack", steps: ["At api.slack.com/apps make an app from scratch and turn on Socket Mode.", "Make an App-Level Token with connections:write (starts xapp-).", "Under OAuth & Permissions add chat:write, im:history, im:read and app_mentions:read, install it and copy the Bot token (starts xoxb-).", "Under Event Subscriptions turn on message.im and app_mention."], fields: [Field(key: "botToken", label: "Bot token (xoxb-)", secret: true), Field(key: "appToken", label: "App-level token (xapp-)", secret: true)]),
        Spec(id: "imessage", title: "iMessage (through Inkbox)", steps: ["Sign up at inkbox.ai and create an agent with iMessage turned on.", "Make an API key for that agent in the Inkbox console and paste it here.", "From your phone, text \u{201C}connect @your-agent-handle\u{201D} to Inkbox\u{2019}s router number (the console shows it). After that, your messages reach the Bot.", "Inkbox limits an agent to about 100 iMessages a day on the base plan."], fields: [Field(key: "apiKey", label: "Inkbox API key", secret: true)]),
        Spec(id: "sms", title: "SMS and phone calls (Twilio)", steps: ["Make a Twilio account and buy a phone number.", "Paste its Account SID, Auth Token and number. Texts to that number reach the Bot.", "For calls, add your own number, a PIN and a public https address. On the server run \u{201C}tailscale funnel --bg 8766\u{201D} and paste the address it prints. Only the phone port is public.", "The Bot calls you, or you call the number and enter the PIN. Say \u{201C}call me\u{201D} in any channel to get a call."],
             fields: [Field(key: "accountSid", label: "Account SID"), Field(key: "authToken", label: "Auth Token", secret: true), Field(key: "number", label: "Twilio number (+15551234567)")],
             calls: [Field(key: "ownerNumber", label: "Your own number (+15551234567)"), Field(key: "pin", label: "Call PIN (4 to 8 digits)", secret: true), Field(key: "publicUrl", label: "Public https address"), Field(key: "language", label: "Call language (en-US)")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                Text("Chat channels on \(serverName)").font(.system(size: 16, weight: .medium))
                Text("One Bot you choose answers messages from your chat channels and can message or phone you. Nobody is answered until you approve them: a stranger gets a short code and nothing else. The channels run on \(serverName), not on this Mac.")
                    .font(.system(size: 12)).lineSpacing(3).foregroundStyle(MacTheme.secondary)
                HStack {
                    Text("Bot that answers").font(.system(size: 14))
                    Spacer()
                    Picker("Bot that answers", selection: Binding(get: { channels.bot ?? "" }, set: { value in run("channels_set_bot", text: value, done: value.isEmpty ? "No Bot answers on channels." : "That Bot now answers on your channels.") })) {
                        Text("Choose a Bot\u{2026}").tag("")
                        ForEach(channels.bots) { Text($0.name).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(!canChange)
                }
                if let feedback { Text(feedback).font(.system(size: 12)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            ForEach(specs) { spec in if let info = channels.channels[spec.id] { channelCard(spec, info) } }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(MacTheme.raised, in: RoundedRectangle(cornerRadius: 16))
    }

    private func stateText(_ info: RemoteChannels.Channel) -> String {
        guard info.enabled else { return "Off" }
        switch info.state.state { case "on": return "Connected"; case "error": return "Not working"; default: return "Starting\u{2026}" }
    }

    private func channelCard(_ spec: Spec, _ info: RemoteChannels.Channel) -> some View {
        card {
            HStack {
                Text(spec.title).font(.system(size: 16, weight: .medium))
                Spacer()
                Text(stateText(info)).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 3)
                    .background(MacTheme.panel, in: Capsule())
                    .foregroundStyle(info.enabled ? (info.state.state == "on" ? Color.green : Color.orange) : MacTheme.secondary)
            }
            if info.enabled, let detail = info.state.detail, !detail.isEmpty { Text(detail).font(.system(size: 12)).foregroundStyle(MacTheme.secondary) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(spec.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").font(.system(size: 12)).foregroundStyle(MacTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(spec.fields) { field(spec.id, $0, info) }
            if !spec.calls.isEmpty {
                Text("Phone calls").font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.secondary).padding(.top, 6)
                ForEach(spec.calls) { field(spec.id, $0, info) }
            }
            HStack(spacing: 10) {
                MacPillButton(title: "Save") { save(spec, info) }.disabled(!canChange || busy)
                MacPillButton(title: info.enabled ? "Turn off" : "Turn on", prominent: !info.enabled) { run("channels_enable", channel: spec.id, text: info.enabled ? "off" : "on", done: info.enabled ? "\(spec.title) is off." : "\(spec.title) is on.") }.disabled(!canChange || busy)
                if spec.id == "sms" { MacPillButton(title: "Call me now") { run("channels_test_call", done: "Calling you now.") }.disabled(!canChange || busy) }
            }
            if spec.id == "sms" {
                Text(channels.calls.ready ? (channels.calls.listening ? "Calls are ready. Twilio reaches the phone port at your public address." : "Calls are set up and starting.") : "Calls need your Twilio number, your own number and an https address.")
                    .font(.system(size: 12)).foregroundStyle(MacTheme.secondary)
            }
            if !info.pending.isEmpty {
                Text("Waiting for your OK").font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.secondary).padding(.top, 6)
                ForEach(info.pending) { person in
                    HStack {
                        Text("\(person.name) \u{00B7} code \(person.code)").font(.system(size: 14))
                        Spacer()
                        MacPillButton(title: "Approve", prominent: true) { run("channels_approve", channel: spec.id, text: person.code, done: "\(person.name) can now message the Bot.") }.disabled(!canChange || busy)
                    }
                }
            }
            if !info.approved.isEmpty {
                Text("Approved").font(.system(size: 13, weight: .semibold)).foregroundStyle(MacTheme.secondary).padding(.top, 6)
                ForEach(info.approved) { person in
                    HStack {
                        Text(person.name == person.id ? person.id : "\(person.name) \u{00B7} \(person.id)").font(.system(size: 14))
                        Spacer()
                        MacPillButton(title: "Remove") { run("channels_remove", channel: spec.id, text: person.id, done: "Removed \(person.name).") }.disabled(!canChange || busy)
                    }
                }
            }
        }
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
        guard let gateway = desktop.gateway, !busy else { return }
        busy = true; feedback = nil
        Task {
            let ok = await gateway.remote.channelCommand(action, channel: channel, text: text, fields: fields)
            if ok { after?(); feedback = done } else { feedback = gateway.remote.error ?? "\(serverName) did not accept that." }
            await reload()
            busy = false
        }
    }
}
