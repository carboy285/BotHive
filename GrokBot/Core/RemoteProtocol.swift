import Foundation

enum RemoteError: Error, LocalizedError, Sendable {
    case incompatible, unauthorized, unavailable
    var errorDescription: String? {
        switch self {
        case .incompatible: "Update the Mac and iPhone apps to compatible versions."
        case .unauthorized: "Sign in again and approve this phone on your computer."
        case .unavailable: "Keep the Mac awake with Bothive running and phone access enabled."
        }
    }
}

struct RemoteProvider: Codable, Equatable, Sendable, Identifiable {
    var provider: CLIProvider
    var version: String
    var id: String { provider.rawValue }
}
/// A computer's own settings as another computer shows them. Keys are never included, only whether each one is set.
struct RemoteHostSettings: Codable, Sendable, Equatable {
    struct Connectors: Codable, Sendable, Equatable { var configured: Bool; var toolkits: [String] }
    var hostName: String
    var platform: String
    var appVersion: String
    var providers: [RemoteProvider]
    var defaultProvider: CLIProvider?
    var apiKeys: [String: Bool]
    var voiceKeys: [String: Bool]
    var connectors: Connectors
    var sharing: Bool
    /// 10.1.1: the owner turned on remote administration (a server used by its address lets the apps change settings and install CLIs).
    var admin: Bool? = nil
    /// 10.1.1: CLIs the computer can install by itself, and how each install is going.
    var installable: [Installable]? = nil
    /// 10.1.2: the chat channels (Telegram, Discord, Slack, iMessage, SMS and calls) this computer or server runs. Never holds a token.
    var channels: RemoteChannels? = nil

    struct Installable: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var guide: String?
        var installed: Bool
        /// "installing", "done" or "failed" while an install has run since the app started.
        var state: String?
        var message: String?
    }
}

/// A Bot request waiting for a yes or no on the Mac that the approved phone can answer too.
struct RemoteApproval: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var detail: String
}
struct RemoteSnapshot: Codable, Sendable {
    var protocolVersion: Int = 1
    var hostName: String
    var revision: String
    var workspace: Workspace
    var running: [UUID]
    var providers: [RemoteProvider]
    var defaultProvider: CLIProvider?
    var overview: Bool? = nil
    var approval: RemoteApproval? = nil

    func botOverview() -> RemoteSnapshot {
        var result = self
        result.overview = true; result.revision = "overview-" + revision
        var latest: [UUID:Entry] = [:]
        for entry in workspace.entries { latest[entry.botID] = entry }
        result.workspace.entries = workspace.bots.compactMap { bot in
            guard var entry = latest[bot.id] else { return nil }; entry.text = String(entry.text.prefix(1000)); return entry
        }
        result.workspace.sharedMemory = nil; result.workspace.teamMessages = nil
        for index in result.workspace.bots.indices { result.workspace.bots[index].memory = nil; result.workspace.bots[index].schedules = nil }
        return result
    }
}
struct RemoteCommand: Codable, Sendable {
    var requestID: UUID = UUID()
    var action: String
    var botID: UUID?
    var text: String?
    var name: String?
    var purpose: String?
    var color: String?
    var configuration: BotAIConfiguration?
    var taskID: UUID?
    var appearance: BotAppearance?
    var attachments: [RemoteAttachment]?
    /// import_bot: an encoded Bot package from another computer on this account.
    var package: Data?
    /// vm_exec: the command to run inside a shared VM (program path first), at most 16 words.
    var argv: [String]?
    /// channels_configure: a chat channel's settings (tokens, numbers), by field name.
    var fields: [String: String]?
}
/// A Linux VM a computer is sharing with the others on the account.
struct RemoteVM: Codable, Sendable, Identifiable, Hashable {
    var botID: UUID
    var botName: String
    var state: String
    var id: UUID { botID }
    init(botID: UUID, botName: String, state: String) { self.botID = botID; self.botName = botName; self.state = state }
    private enum Keys: String, CodingKey { case botID, botName, name, state }
    /// Older Windows builds sent `name` instead of `botName`, so either is accepted. A missing botID is reported by name.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        guard let id = try values.decodeIfPresent(UUID.self, forKey: .botID) else {
            throw CloudError.message("The other computer’s VM list is missing “botID”. Update Bothive on both computers.")
        }
        botID = id
        botName = try values.decodeIfPresent(String.self, forKey: .botName) ?? values.decodeIfPresent(String.self, forKey: .name) ?? "Shared VM"
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? "ready"
    }
}
/// How a command sent to a shared VM is going. `status` is running, done or error.
struct RemoteVMResult: Codable, Sendable {
    var status: String
    var output: String?
}
/// An image sent with a message. Hosts store it in the Bot's Attachments folder.
struct RemoteAttachment: Codable, Sendable, Equatable {
    static let maxCount = 3
    static let maxTotalBytes = 2_400_000
    var name: String
    var mime: String
    var data: Data
}
struct RemoteFile: Codable, Sendable, Identifiable { var name: String; var id: String { name } }

/// Application RPC DTOs carried inside encrypted relay packets; no HTTP listener.
struct RemoteHostRequest: Sendable {
    let method: String
    let target: String
    let body: Data
}
struct RemoteHostResponse: Sendable {
    var status: Int = 200
    var body: Data = Data()
    static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> RemoteHostResponse {
        RemoteHostResponse(status:status,body:try CloudCoding.encoder().encode(value))
    }
    static func error(_ status: Int, _ message: String) -> RemoteHostResponse {
        (try? .json(["error":message],status:status)) ?? RemoteHostResponse(status:500)
    }
}


struct RemoteBrowserPreview: Codable, Sendable {
    var title: String
    var url: String
    var imageData: Data?
}


/// What a computer reports about its chat channels (10.1.2). Settings that are secrets arrive only as "is it set".
struct RemoteChannels: Codable, Sendable, Equatable {
    enum FieldValue: Codable, Sendable, Equatable {
        case isSet(Bool), text(String)
        init(from decoder: Decoder) throws {
            let box = try decoder.singleValueContainer()
            if let flag = try? box.decode(Bool.self) { self = .isSet(flag) } else { self = .text(try box.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var box = encoder.singleValueContainer()
            switch self { case .isSet(let value): try box.encode(value); case .text(let value): try box.encode(value) }
        }
        var text: String? { if case .text(let value) = self { return value }; return nil }
        var set: Bool { switch self { case .isSet(let value): return value; case .text(let value): return !value.isEmpty } }
    }
    struct State: Codable, Sendable, Equatable { var state: String; var detail: String? }
    struct Approved: Codable, Sendable, Equatable, Identifiable { var id: String; var name: String; var me: Bool? = nil }
    struct Waiting: Codable, Sendable, Equatable, Identifiable { var name: String; var code: String; var id: String { code } }
    struct Channel: Codable, Sendable, Equatable {
        var name: String
        var enabled: Bool
        var configured: Bool
        var fields: [String: FieldValue]
        var state: State
        var approved: [Approved]
        var pending: [Waiting]
    }
    struct BotChoice: Codable, Sendable, Equatable, Identifiable { var id: String; var name: String }
    struct Calls: Codable, Sendable, Equatable { var ready: Bool; var listening: Bool }
    struct Settings: Codable, Sendable, Equatable {
        var fast: Bool = true
        var whenBusy: String = "steer"
        var reachOn: String? = nil
        var escalate: String = "call"
        var escalateMinutes: Int = 10
        var quietStart: Int = 22
        var quietEnd: Int = 8
    }
    struct Voice: Codable, Sendable, Equatable, Identifiable { var id: String; var name: String; var available: Bool = true }
    struct Question: Codable, Sendable, Equatable { var question: String }
    struct Inkbox: Codable, Sendable, Equatable {
        var ready: Bool = false
        var state: State? = nil
        var ownerNumber: String? = nil
        var voices: [Voice] = []
        var pendingAsk: Question? = nil
    }
    var bot: String?
    var bots: [BotChoice]
    var channels: [String: Channel]
    var calls: Calls
    var settings: Settings? = nil
    var inkbox: Inkbox? = nil
}
