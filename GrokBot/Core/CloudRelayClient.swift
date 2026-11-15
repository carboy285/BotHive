import Foundation

/// Request/response over the encrypted mailbox.
///
/// 0.9.9: requests no longer wait in line. Several can be in flight at once (a message you send doesn't queue behind
/// the background state check), one mailbox check runs at a time, and replies are sorted to their request by ID.
/// Between checks it sleeps until the relay pings this device (`CloudWake`) or a short timer runs out.
/// The state loop still issues one state request at a time, so state deltas stay in order.
@MainActor
final class CloudRelayClient {
    let account: CloudAccount
    /// Requests waiting for a reply, and which computer each one is waiting on.
    private var waiting: [UUID: UUID] = [:]
    /// Replies collected by whichever request happened to check the mailbox.
    private var inbox: [UUID: CloudPacket] = [:]
    private var checking = false
    init(account: CloudAccount) { self.account = account }

    func fetch(_ peer: CloudDevice, target: String, command: RemoteCommand? = nil) async throws -> CloudResponse {
        try Task.checkCancellation(); try account.pin(peer)
        let id = UUID(), owner = account.session?.user.id
        waiting[id] = peer.id
        defer { waiting[id] = nil; inbox[id] = nil }
        let request = CloudRequest(method:command == nil ? "GET":"POST",target:target,body:try command.map { try CloudCoding.encoder().encode($0) } ?? Data())
        let payload = try CloudCoding.encoder().encode(request)
        try await account.send(payload,to:peer,id:id,kind:"request")
        let started = Date(), deadline = Date().addingTimeInterval(command == nil ? 12 : 35)
        var nextResend = Date().addingTimeInterval(2)
        while Date() < deadline {
            try Task.checkCancellation()
            guard account.session?.user.id == owner else { throw CloudError.signedOut }
            let seen = account.wake.pulse.count
            if let packet = inbox.removeValue(forKey: id) { return try finish(packet, from: peer) }
            if !checking {
                checking = true
                do { route(try await account.poll()); checking = false } catch { checking = false; throw error }
                if let packet = inbox.removeValue(forKey: id) { return try finish(packet, from: peer) }
            }
            if Date() >= nextResend {
                try await account.send(payload,to:peer,id:id,kind:"request")
                nextResend = Date().addingTimeInterval(3)
            }
            // With the wake channel up, the ping usually ends this wait within one network round trip.
            // The timer is only a safety net (and the whole mechanism when the channel is down).
            let elapsed = Date().timeIntervalSince(started)
            let limit: Duration = account.wake.connected ? .milliseconds(600)
                : elapsed < 2 ? .milliseconds(100) : elapsed < 6 ? .milliseconds(250) : .milliseconds(500)
            await account.wake.pulse.wait(after: seen, upTo: limit)
        }; throw CloudError.timeout
    }

    /// Files each packet under the request it answers. Anything else is stale (a timed-out request's reply) and is cleared.
    private func route(_ packets: [CloudPacket]) {
        for packet in packets {
            if packet.kind == "response", let peer = waiting[packet.id], packet.sender == peer { inbox[packet.id] = packet }
            else { account.acknowledgeLater(packet) }
        }
        // Another request may be asleep waiting for one of these.
        if !packets.isEmpty { account.wake.pulse.signal() }
    }

    private func finish(_ packet: CloudPacket, from peer: CloudDevice) throws -> CloudResponse {
        // The reply is in hand; clearing it from the mailbox needn't hold up the caller.
        account.acknowledgeLater(packet)
        let response: CloudResponse
        do {
            let data = try account.decrypt(packet,peer:peer)
            response = try CloudCoding.decoder().decode(CloudResponse.self,from:data)
        } catch {
            throw CloudError.message("A reply from \(peer.name) could not be verified or decoded. Quit older copies of Bothive on that computer and reopen the updated app.")
        }
        guard (200...299).contains(response.status) else {
            if response.status == 403 { throw CloudError.approvalRequired }
            let object = try? JSONDecoder().decode([String:String].self,from:response.body)
            throw CloudError.message(object?["error"] ?? "Desktop request failed (\(response.status)).")
        }
        return response
    }
}
