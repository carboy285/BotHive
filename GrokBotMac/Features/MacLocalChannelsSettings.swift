import SwiftUI

/// Settings → Channels (10.1.2): chat channels that run on this Mac. SMS and phone calls need a public address, so they stay on a server.
struct MacLocalChannelsSettings: View {
    @EnvironmentObject private var desktop: MacAppModel
    @State private var tick = 0

    var body: some View {
        let live = desktop.channels
        let _ = tick // Re-reads the status when it changes, without rebuilding the screen (so a half-typed token is kept).
        MacChannelsSection(channels: live.status(), serverName: "this Mac", canChange: true, reload: { tick += 1 },
                           execute: { action, channel, text, fields in await live.execute(action, channel: channel, text: text, fields: fields) },
                           footnote: "These run on this Mac, so they work while Bothive is open. Phone calls here go through Inkbox (turn on iMessage and add your number). Twilio SMS and calls need a public address, so set those up on a Bothive server (view the server and open its settings).")
            .onReceive(live.objectWillChange) { _ in tick += 1 }
            .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(3)); tick += 1 } }
    }
}
