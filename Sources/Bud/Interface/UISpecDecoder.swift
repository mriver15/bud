import Foundation

/// The local parser/repair pass for the output dialect (§6.3): a small tagged
/// envelope the model writes inside its prose, extracted and validated here.
///
/// The envelope is a fenced block tagged `bud-ui`:
///
///     ```bud-ui
///     {"title": "…", "components": […]}
///     ```
///
/// Parsing is deliberately lenient — Foundation tolerates the trailing commas
/// models habitually emit — and `UISpec`'s total decoding does the rest:
/// unknown component types become placeholders and are *reported back as
/// repairs* for the repair-rate measurement. A broken envelope that cannot
/// yield a usable surface leaves the answer as prose rather than turning into
/// a silently blank panel.
public enum UISpecDecoder {
    public struct DecodeResult: Sendable, Equatable {
        public var payload: AssistantPayload
        /// The envelope's JSON, exactly what a surface segment carries.
        public var rawJSON: JSONValue?
        /// What the decode pass had to repair or report, for the repair-rate
        /// measurement: degraded component types, named in tree order.
        public var repairs: [String]

        public init(payload: AssistantPayload, rawJSON: JSONValue?, repairs: [String]) {
            self.payload = payload
            self.rawJSON = rawJSON
            self.repairs = repairs
        }
    }

    /// The envelope a round-trip costs beyond the JSON itself. Measured against
    /// the `render_ui` tool schema in the experiment: the dialect pays this
    /// only when the answer actually draws a surface.
    public static let envelopeOverhead = "```bud-ui\n".count + "\n```".count

    public static func decode(_ text: String) -> DecodeResult {
        guard let envelope = envelope(in: text) else {
            return DecodeResult(payload: .markdown(text), rawJSON: nil, repairs: [])
        }

        var repairs: [String] = []
        let trimmed = envelope.json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = JSONValue(parsing: trimmed), let spec = UISpec(json: json) else {
            // The envelope held no usable surface: the answer stays prose,
            // untouched.
            return DecodeResult(payload: .markdown(text), rawJSON: nil, repairs: [])
        }
        if !spec.unsupportedTypes.isEmpty {
            repairs.append(
                "unsupported component types became placeholders: \(spec.unsupportedTypes.joined(separator: ", "))"
            )
        }

        let markdown = text.replacingCharacters(in: envelope.wholeRange, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if markdown.isEmpty {
            return DecodeResult(payload: .budUI(spec), rawJSON: json, repairs: repairs)
        }
        return DecodeResult(payload: .mixed(markdown: markdown, ui: spec), rawJSON: json, repairs: repairs)
    }

    /// The envelope, when the answer carries one: the opening fence must tag
    /// `bud-ui` (an optional language hint may follow), the closing fence is
    /// the next line consisting of backticks.
    private struct Envelope {
        let json: String
        let wholeRange: Range<String.Index>
    }

    private static func envelope(in text: String) -> Envelope? {
        guard let opening = try? NSRegularExpression(pattern: #"```bud-ui[^\n]*\n"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = opening.firstMatch(in: text, range: range),
              let openEnd = Range(match.range, in: text) else { return nil }

        var search = text[openEnd.upperBound...]
        while let fence = search.firstIndex(of: "`") {
            // The closing fence starts at a line boundary and is backticks alone.
            if fence == search.startIndex || search[search.index(before: fence)] == "\n" {
                let lineEnd = search[fence...].firstIndex(of: "\n") ?? search.endIndex
                let fenceLine = search[fence..<lineEnd]
                if fenceLine.allSatisfy({ $0 == "`" }), fenceLine.count >= 3 {
                    let jsonStart = openEnd.upperBound
                    let jsonEnd = fence
                    let wholeRange = openEnd.lowerBound..<lineEnd
                    return Envelope(
                        json: String(text[jsonStart..<jsonEnd]),
                        wholeRange: wholeRange
                    )
                }
            }
            search = search[search.index(after: fence)...]
        }
        return nil
    }
}
