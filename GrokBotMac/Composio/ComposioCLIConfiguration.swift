import Foundation

struct ComposioCLIConfiguration {
    var arguments: [String] = []
    var environment: [String:String] = [:]
    private var files: [URL] = []
    func cleanup() { for file in files { try? FileManager.default.removeItem(at: file) } }

    /// `tools` (10.2) is Bothive's own local tool server for this run. Only Claude Code takes it for now.
    static func make(provider: CLIProvider, directory: URL, sessionURL: String?, tools: BothiveToolsGrant? = nil) throws -> Self {
        let tools = provider == .claude ? tools.flatMap { Self.loopback($0.url) ? $0 : nil } : nil
        guard sessionURL != nil || tools != nil else { return Self() }
        if let sessionURL { guard ComposioClient.trustedURL(sessionURL) != nil else { throw ComposioError.invalidResponse } }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ComposioBridge").path
        if sessionURL != nil { guard FileManager.default.isExecutableFile(atPath: helper) else { throw CLIError.invalidOutput } }
        let name = "opengrokbot-composio", variable = "OPENGROKBOT_COMPOSIO_MCP_URL"
        var config = Self(environment: sessionURL.map { [variable: $0] } ?? [:])
        // All generated configs contain environment placeholders; no key or capability URL is written to disk.
        let server: [String:Any] = ["command":helper, "args":[String](), "env":[variable:"${\(variable)}"]]
        func write(_ relative: String, bytes: Data) throws {
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            // App-owned per-Bot working directories only. Never replace unrelated project settings.
            if FileManager.default.fileExists(atPath: url.path) {
                guard try Data(contentsOf: url) == bytes else { throw CLIError.invalidOutput }
                config.files.append(url); return
            }
            try bytes.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url.path)
            config.files.append(url)
        }
        func json(_ object: [String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        if sessionURL == nil && provider != .claude { return Self() }
        do {
            switch provider {
            case .codex:
                // TOML strings use JSON-compatible escaping for ordinary path strings.
                let quoted = String(data: try JSONSerialization.data(withJSONObject: [helper], options: [.withoutEscapingSlashes]), encoding: .utf8)!.dropFirst().dropLast()
                config.arguments = ["-c", "mcp_servers.\(name).command=\(quoted)", "-c", "mcp_servers.\(name).env_vars=[\"\(variable)\"]"]
            case .claude:
                let filename = ".composio-\(UUID().uuidString).json"
                var servers: [String:Any] = sessionURL == nil ? [:] : [name:server]
                if let tools {
                    // The token travels in the environment; the file only names the variable.
                    servers[MacToolServer.serverName] = ["type":"http", "url":tools.url, "headers":["Authorization":"Bearer ${\(MacToolServer.tokenVariable)}"]]
                    config.environment[MacToolServer.tokenVariable] = tools.token
                    config.environment["MCP_TOOL_TIMEOUT"] = "600000"
                }
                try write(filename, bytes: json(["mcpServers":servers]))
                config.arguments = ["--mcp-config",directory.appendingPathComponent(filename).path]
            case .grok:
                let quoted = String(data: try JSONSerialization.data(withJSONObject: [helper], options: [.withoutEscapingSlashes]), encoding: .utf8)!.dropFirst().dropLast()
                try write(".grok/config.toml", bytes: Data("[mcp_servers.\(name)]\ncommand = \(quoted)\n[mcp_servers.\(name).env]\n\(variable) = \"${\(variable)}\"\n".utf8))
            case .opencode:
                let filename = ".composio-\(UUID().uuidString).json"
                try write(filename, bytes: json(["mcp":[name:["type":"local", "command":[helper], "enabled":true, "environment":[variable:"{env:\(variable)}"]]]]))
                config.environment["OPENCODE_CONFIG"] = directory.appendingPathComponent(filename).path
            case .gemini:
                try write(".gemini/settings.json", bytes: json(["mcpServers":[name:server]]))
            case .ollama, .lmstudio:
                break // Local model servers have no MCP client; connected apps are not offered to them.
            }
            return config
        } catch { config.cleanup(); throw error }
    }

    /// Only the app's own listener on this Mac.
    static func loopback(_ address: String) -> Bool {
        guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1", url.port != nil, url.path == "/mcp", url.user == nil, url.query == nil else { return false }
        return true
    }
}
