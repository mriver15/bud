import Foundation

/// Images that arrive as bytes rather than as a URL.
///
/// An MCP server can return an image content block — a sprite, a chart, a
/// screenshot — and those bytes have nowhere to live: `AsyncImage` wants a URL,
/// and the transcript has no room for a base64 string. So they are written into
/// Bud's own directory and referred to by path, exactly the way the browser's
/// screenshots are.
///
/// It also means a tool that produces an image does not need somewhere public to
/// put it first. A local MCP server can hand back the bytes.
public enum ImageAssets {
    public static var directory: URL {
        BudConfigLoader.budDirectory.appendingPathComponent("images", isDirectory: true)
    }

    /// Big enough for a screenshot, small enough that a server cannot fill a disk
    /// by returning one answer.
    private static let limit = 12 * 1024 * 1024
    private static let keep = 80

    /// Writes the bytes and returns the file, or nil when they are not an image
    /// worth keeping.
    public static func store(base64: String, mimeType: String) -> URL? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        guard !data.isEmpty, data.count <= limit else { return nil }
        // Checked against the bytes, not against what the server called it. A
        // declared type is a claim, and this decides where on disk something is
        // written and what it is handed to as.
        guard let kind = kind(of: data) else { return nil }

        // An image from a server is a picture of whatever that server could see,
        // so the directory and the file are kept to the owner for the same reason
        // the browser's screenshots are.
        BudConfigLoader.createOwnerOnlyDirectory(directory)
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(kind.extension)")
        do {
            try BudConfigLoader.writeOwnerOnly(data, to: url)
            prune()
            return url
        } catch {
            return nil
        }
    }

    /// What the bytes actually are, or nil when they are not an image Bud will
    /// render.
    private static func kind(of data: Data) -> (extension: String, mime: String)? {
        let head = [UInt8](data.prefix(12))
        func has(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard head.count >= offset + bytes.count else { return false }
            return Array(head[offset..<(offset + bytes.count)]) == bytes
        }
        if has([0x89, 0x50, 0x4E, 0x47]) { return ("png", "image/png") }
        if has([0xFF, 0xD8, 0xFF]) { return ("jpg", "image/jpeg") }
        if has([0x47, 0x49, 0x46, 0x38]) { return ("gif", "image/gif") }
        // RIFF....WEBP
        if has([0x52, 0x49, 0x46, 0x46]), has([0x57, 0x45, 0x42, 0x50], at: 8) {
            return ("webp", "image/webp")
        }
        // SVG is text, and its first meaningful bytes are a tag rather than a
        // signature. Recognised so it is written as the markup it is.
        if let text = String(data: data.prefix(512), encoding: .utf8),
           text.contains("<svg") {
            return ("svg", "image/svg+xml")
        }
        return nil
    }

    /// Keeps the newest few. Every answer carrying an image leaves one behind, and
    /// nothing else will ever come and clear them out.
    private static func prune() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let dated = entries.compactMap { url -> (URL, Date)? in
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return date.map { (url, $0) }
        }
        .sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keep) {
            try? manager.removeItem(at: url)
        }
    }
}
