import Foundation

// MARK: - Outline

/// One line of a page outline.
///
/// Two kinds of line live in one type rather than two: a plain region — a
/// heading or an image — that can be read, and an actionable line that carries
/// the ref a later tool call acts on. The outline is one ordered stream and a
/// delta walks it in order, so splitting the kinds would only force the walk to
/// stitch them back together.
public struct OutlineLine: Sendable, Equatable, Hashable {
    /// The rendered line, exactly as a snapshot shows it.
    public let text: String
    /// The reference a later action uses, when this line carries one.
    public let ref: Int?

    public init(text: String, ref: Int?) {
        self.text = text
        self.ref = ref
    }
}

/// A page outline in structured form.
///
/// The snapshot text is this rendered; keeping the structure is what lets a
/// delta compare refs and regions without re-parsing prose it just built.
public struct PageOutline: Sendable, Equatable {
    public var url: String
    public var title: String
    public var lines: [OutlineLine]

    public init(url: String, title: String, lines: [OutlineLine]) {
        self.url = url
        self.title = title
        self.lines = lines
    }
}

extension PageOutline {
    /// The outline rendered to the text a snapshot returns: identity first, then
    /// the lines, truncated to `maxLines` with a note when the tail is dropped.
    public func render(maxLines: Int = 220) -> String {
        let header = "\(title)\n\(url)\n"
        let shown = lines.prefix(maxLines)
        var out = header + "\n" + shown.map(\.text).joined(separator: "\n")
        if lines.count > shown.count {
            out += "\n…[\(lines.count - shown.count) more lines]"
        }
        return out
    }
}

// MARK: - Delta

/// The difference between two outlines of the same page.
///
/// Pure and deterministic: `compare` reads two outlines and writes a delta,
/// touching no web view or shared state, so it is testable in isolation. Refs
/// are matched by number — they are assigned fresh on every snapshot in document
/// order, so a number means "the nth actionable element", and a delta over
/// numbers is the honest description of what the page did to its controls.
public struct OutlineDelta: Sendable, Equatable {
    /// A ref present in both outlines whose line text changed.
    public struct RefChange: Sendable, Equatable, Hashable {
        public let ref: Int
        public let before: String
        public let after: String

        public init(ref: Int, before: String, after: String) {
            self.ref = ref
            self.before = before
            self.after = after
        }
    }

    public var urlChanged: Bool
    public var titleChanged: Bool
    /// Refs present now but not before.
    public var newRefs: [OutlineLine]
    /// Refs present in both whose text changed.
    public var changedRefs: [RefChange]
    /// Refs present before but not now.
    public var invalidatedRefs: [OutlineLine]
    /// Plain region lines present now but not before.
    public var newText: [String]
    /// Plain region lines present before but not now.
    public var removedText: [String]

    public init(
        urlChanged: Bool,
        titleChanged: Bool,
        newRefs: [OutlineLine],
        changedRefs: [RefChange],
        invalidatedRefs: [OutlineLine],
        newText: [String],
        removedText: [String]
    ) {
        self.urlChanged = urlChanged
        self.titleChanged = titleChanged
        self.newRefs = newRefs
        self.changedRefs = changedRefs
        self.invalidatedRefs = invalidatedRefs
        self.newText = newText
        self.removedText = removedText
    }

    /// True when the two outlines described the same page in the same way.
    public var isEmpty: Bool {
        !urlChanged && !titleChanged
            && newRefs.isEmpty && changedRefs.isEmpty && invalidatedRefs.isEmpty
            && newText.isEmpty && removedText.isEmpty
    }

    /// The difference between two outlines of the same page.
    public static func compare(previous: PageOutline, current: PageOutline) -> OutlineDelta {
        let previousByRef = byRef(previous.lines)
        let currentByRef = byRef(current.lines)

        let previousRefs = Set(previousByRef.keys)
        let currentRefs = Set(currentByRef.keys)

        let newRefs = currentRefs.subtracting(previousRefs)
            .compactMap { currentByRef[$0] }
            .sorted { ($0.ref ?? 0) < ($1.ref ?? 0) }
        let invalidatedRefs = previousRefs.subtracting(currentRefs)
            .compactMap { previousByRef[$0] }
            .sorted { ($0.ref ?? 0) < ($1.ref ?? 0) }
        let changedRefs = currentRefs.intersection(previousRefs)
            .compactMap { ref -> RefChange? in
                guard let before = previousByRef[ref], let after = currentByRef[ref],
                      before.text != after.text
                else { return nil }
                return RefChange(ref: ref, before: before.text, after: after.text)
            }
            .sorted { $0.ref < $1.ref }

        let previousText = previous.lines.filter { $0.ref == nil }.map(\.text)
        let currentText = current.lines.filter { $0.ref == nil }.map(\.text)

        return OutlineDelta(
            urlChanged: previous.url != current.url,
            titleChanged: previous.title != current.title,
            newRefs: newRefs,
            changedRefs: changedRefs,
            invalidatedRefs: invalidatedRefs,
            newText: removed(from: currentText, in: previousText),
            removedText: removed(from: previousText, in: currentText)
        )
    }

    /// The delta rendered for the model: the current identity, then each
    /// difference under a short heading. "Nothing changed" is said in words,
    /// because an empty delta is the signal to act on what it already has.
    public func render(current: PageOutline) -> String {
        if isEmpty {
            return "\(current.title)\n\(current.url)\n\nNothing changed since the last outline."
        }
        var sections: [String] = ["\(current.title)\n\(current.url)\n"]
        if urlChanged {
            sections.append("URL changed: \(current.url)")
        }
        if titleChanged {
            sections.append("Title changed: \(current.title)")
        }
        if !changedRefs.isEmpty {
            sections.append("Changed refs:")
            for change in changedRefs {
                sections.append("  \(change.after)   (was: \(Self.withoutRef(change.before, change.ref)))")
            }
        }
        if !newRefs.isEmpty {
            sections.append("New refs:")
            for line in newRefs {
                sections.append("  \(line.text)")
            }
        }
        if !invalidatedRefs.isEmpty {
            sections.append("Invalidated refs (do not reuse):")
            for line in invalidatedRefs {
                sections.append("  \(line.text)")
            }
        }
        if !newText.isEmpty || !removedText.isEmpty {
            sections.append("Text changed:")
            for line in newText { sections.append("  + \(line)") }
            for line in removedText { sections.append("  - \(line)") }
        }
        return sections.joined(separator: "\n")
    }

    // MARK: - Internals

    /// Ref number -> line, keyed so a delta can tell "gone", "new" and "same but
    /// different" apart. A ref appears once per outline by construction; a later
    /// write wins so the build stays deterministic even if that were ever untrue.
    private static func byRef(_ lines: [OutlineLine]) -> [Int: OutlineLine] {
        var out: [Int: OutlineLine] = [:]
        for line in lines {
            if let ref = line.ref { out[ref] = line }
        }
        return out
    }

    /// The entries of `a` not accounted for in `b`, counting duplicates, in `a`'s
    /// order. A plain multiset difference: a heading has no ref to identify it
    /// by, so its identity is the text itself.
    private static func removed(from a: [String], in b: [String]) -> [String] {
        var remaining = b.reduce(into: [String: Int]()) { counts, line in
            counts[line, default: 0] += 1
        }
        var out: [String] = []
        for line in a {
            if let count = remaining[line], count > 0 {
                remaining[line] = count - 1
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// The line with its `[ref=N]` marker removed, so a changed ref reads once.
    private static func withoutRef(_ line: String, _ ref: Int) -> String {
        line.replacingOccurrences(of: " [ref=\(ref)]", with: "")
    }
}
