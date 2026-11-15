import Foundation

/// Turns what a person dropped on a chat (files and folders) into a list of regular files to attach (10.1).
/// Folders are read breadth-first, up to four levels deep, skipping hidden entries, links and build folders. Nothing outside what was dropped is followed.
enum MacDrop {
    static let maxBytes = 20_000_000
    static let maxVisited = 2_000
    static let maxDepth = 4
    static let skippedFolders: Set<String> = ["node_modules", "__pycache__", "venv", "dist", "build", "target"]

    /// `skipped` counts files left out because of the limit, their size, or because they were empty.
    static func expand(_ urls: [URL], limit: Int = 10) -> (files: [URL], skipped: Int) {
        var files: [URL] = []
        var skipped = 0
        var visited = 0
        var queue: [(folder: URL, depth: Int)] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var scoped: [URL] = []
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }

        func take(_ url: URL, size: Int) {
            if size <= 0 || size > maxBytes { skipped += 1 } else if files.count < limit { files.append(url) } else { skipped += 1 }
        }

        for url in urls {
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true { take(url, size: values.fileSize ?? 0) }
            else if values.isDirectory == true { queue.append((url, 0)) }
        }

        var index = 0
        while index < queue.count, visited < maxVisited {
            let current = queue[index]
            index += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.folder.path).sorted() else { continue }
            for name in names {
                visited += 1
                if visited > maxVisited { break }
                if name.hasPrefix(".") || skippedFolders.contains(name) { continue }
                let child = current.folder.appendingPathComponent(name)
                guard let values = try? child.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
                if values.isRegularFile == true { take(child, size: values.fileSize ?? 0) }
                else if values.isDirectory == true, current.depth < maxDepth { queue.append((child, current.depth + 1)) }
            }
        }
        return (files, skipped)
    }
}
