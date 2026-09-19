import Foundation

/// Shrinks a tool schema without changing what it can express.
///
/// The tool block is the one part of a request that grows when a server is
/// installed once and then never looked at again, and most of that growth is
/// documentation rather than shape: a long description, or a `title` that
/// restates the name. The compactor keeps the shape — types, enums, bounds,
/// required keys, properties, items — and trims the prose, so the model still
/// writes valid arguments but carries less on every request.
///
/// It is pure and deterministic: the same descriptor always compacts to the same
/// result, which is what makes `--measure --compact` comparable to `--measure`.
public enum DescriptorCompactor {
    /// Descriptions longer than this are truncated to their first characters
    /// with an ellipsis. One short paragraph fits inside it, and the prose past
    /// that point rarely changes which arguments a model writes.
    static let maxDescriptionLength = 240

    /// The compacted form of a descriptor. Name, provider identity and the
    /// schema's shape are preserved; only prose is trimmed.
    public static func compact(_ descriptor: ToolDescriptor) -> ToolDescriptor {
        var result = descriptor
        result.description = compactDescription(descriptor.description, name: descriptor.name)
        result.schema = compactSchema(descriptor.schema)
        return result
    }

    /// The descriptor-level description. One that merely repeats the tool's name
    /// carries nothing the `name` does not already say, so it is dropped rather
    /// than paid for on every request.
    private static func compactDescription(_ text: String, name: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(trimmedName) == .orderedSame { return "" }
        return truncating(text)
    }

    /// Walks the schema generically, so an arbitrary server's schema gets the
    /// same treatment as the built-ins'. `title` keys are dropped and
    /// `description` strings are truncated; every other key is preserved, so the
    /// result is still a valid JSON Schema.
    private static func compactSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let pairs):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(pairs.count)
            for (key, child) in pairs {
                switch key {
                case "title":
                    continue
                case "description":
                    if case .string(let text) = child {
                        out[key] = .string(truncating(text))
                    } else {
                        out[key] = child
                    }
                default:
                    out[key] = compactSchema(child)
                }
            }
            return .object(out)
        case .array(let items):
            return .array(items.map(compactSchema))
        case .string, .number, .bool, .null:
            return value
        }
    }

    private static func truncating(_ text: String) -> String {
        guard text.count > maxDescriptionLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxDescriptionLength)
        return String(text[..<end]) + "…"
    }
}
