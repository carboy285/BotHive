import Foundation

/// A picture that arrived with a chat message (10.1.2). The address may need a header (Slack wants the bot token).
struct ChannelMedia: Sendable, Equatable {
    var url: String
    var contentType = ""
    var name = ""
    var headers: [String: String] = [:]
}

/// Saves pictures from chat channels into a Bot's Attachments folder, so the Bot can read them like pictures attached in the app.
/// Only PNG, JPEG, GIF, WebP and HEIC pictures are kept, judged by their bytes and not by what the sender claims.
/// iPhone photos are often HEIC, which no AI CLI reads, so those are converted to JPEG with the Mac's own `sips`.
enum ChannelMediaStore {
    static let maxBytes = 20_000_000, maxCount = 3

    enum Kind: Equatable { case png, jpg, gif, webp, heic
        var fileExtension: String { switch self { case .png: "png"; case .jpg: "jpg"; case .gif: "gif"; case .webp: "webp"; case .heic: "jpg" } }
    }
    struct Saved: Equatable { var names: [String] = []; var problems: [String] = [] }

    static func sniff(_ bytes: Data) -> Kind? {
        let b = [UInt8](bytes.prefix(16))
        func text(_ range: Range<Int>) -> String { b.count >= range.upperBound ? String(decoding: b[range], as: UTF8.self) : "" }
        if b.count > 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png }
        if b.count > 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpg }
        if text(0..<4) == "GIF8" { return .gif }
        if text(0..<4) == "RIFF", text(8..<12) == "WEBP" { return .webp }
        if text(4..<8) == "ftyp", ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "heim", "heis"].contains(text(8..<12)) { return .heic }
        return nil
    }

    private static func cleanName(_ raw: String) -> String {
        let base = (raw as NSString).deletingPathExtension
        let scalars = base.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == "\\" ? "_" : String($0) }.joined()
        let trimmed = String(scalars.prefix(40)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Photo" : trimmed
    }

    /// Writes one picture. Returns the stored file name. Throws a ChannelError whose message says what was wrong.
    static func store(_ bytes: Data, name: String, into directory: URL) async throws -> String {
        guard !bytes.isEmpty, bytes.count <= maxBytes, let kind = sniff(bytes) else { throw ChannelError(message: "That is not a PNG, JPEG, GIF or WebP picture.", code: 1) }
        let folder = directory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stored = UUID().uuidString + "-" + cleanName(name) + "." + kind.fileExtension
        let target = folder.appendingPathComponent(stored)
        if kind == .heic {
            let converted = try await Task.detached { () throws -> Data in
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let input = temp.appendingPathExtension("heic"), output = temp.appendingPathExtension("jpg")
                defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
                try bytes.write(to: input)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
                process.arguments = ["-s", "format", "jpeg", input.path, "--out", output.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0, let data = try? Data(contentsOf: output), sniff(data) == .jpg else { throw ChannelError(message: "That photo could not be converted.", code: 2) }
                return data
            }.value
            try converted.write(to: target, options: .atomic)
        } else {
            try bytes.write(to: target, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return stored
    }

    /// Downloads and stores up to three pictures. Problems are described in plain words for the Bot to pass on.
    @MainActor
    static func save(_ items: [ChannelMedia], into directory: URL) async -> Saved {
        var saved = Saved()
        for item in items.prefix(maxCount) {
            do {
                guard let url = URL(string: item.url), url.scheme == "https" else { throw ChannelError(message: "bad address", code: 3) }
                var request = URLRequest(url: url, timeoutInterval: 30)
                for (key, value) in item.headers { request.setValue(value, forHTTPHeaderField: key) }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { throw ChannelError(message: "download failed", code: 3) }
                saved.names.append(try await store(data, name: item.name, into: directory))
            } catch let error as ChannelError where error.code == 1 {
                saved.problems.append("a file that is not a PNG, JPEG, GIF or WebP picture was skipped")
            } catch let error as ChannelError where error.code == 2 {
                saved.problems.append("a photo arrived in the HEIC format and could not be converted. Ask them to send it as a JPEG or a screenshot")
            } catch {
                saved.problems.append("a picture could not be downloaded")
            }
        }
        return saved
    }
}
