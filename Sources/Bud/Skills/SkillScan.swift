import Foundation

/// A single thing worth knowing about a skill before installing it.
public struct SkillFinding: Sendable, Identifiable, Equatable {
    /// How much it should stand in the way.
    ///
    /// Ordered, so a report can be summarised by its worst finding rather than by
    /// counting them — one blocked file is not offset by nine notes.
    public enum Severity: Int, Comparable, Sendable, CaseIterable {
        /// Refused. Nothing about this can be made safe by reading it first.
        case blocked
        /// Installing is possible, but only after saying so explicitly.
        case dangerous
        /// Allowed, and shown.
        case caution
        /// Worth knowing.
        case note

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .blocked: return "Blocked"
            case .dangerous: return "Needs review"
            case .caution: return "Worth knowing"
            case .note: return "Note"
            }
        }
    }

    public var severity: Severity
    public var title: String
    public var detail: String
    /// The file it was found in, relative to the skill folder.
    public var file: String?

    public var id: String { "\(severity.rawValue)|\(title)|\(file ?? "")" }
}

/// What scanning one skill folder found.
public struct SkillScanReport: Sendable {
    public var findings: [SkillFinding] = []
    public var fileCount = 0
    public var byteCount = 0
    /// Files that would run if something ran them.
    public var executables: [String] = []
    /// What the skill says it needs, from the standard's `allowed-tools`.
    public var declaresTools: String?

    public var isBlocked: Bool { findings.contains { $0.severity == .blocked } }
    public var needsReview: Bool { findings.contains { $0.severity == .dangerous } }

    public func findings(at severity: SkillFinding.Severity) -> [SkillFinding] {
        findings.filter { $0.severity == severity }
    }

    /// The one-line verdict.
    public var summary: String {
        if isBlocked { return "This skill cannot be installed." }
        if needsReview {
            let count = findings(at: .dangerous).count
            return "\(count) thing\(count == 1 ? "" : "s") to look at before installing."
        }
        let cautious = findings(at: .caution).count
        if cautious > 0 { return "Nothing alarming — \(cautious) thing\(cautious == 1 ? "" : "s") worth knowing." }
        return "Nothing found."
    }
}

/// Inspects a skill before it is installed.
///
/// A skill is instructions that go straight into the model's context, plus any
/// code it ships. That is two different risks with one entry point, and both are
/// decided here, before anything is written to disk.
///
/// Deliberately static. A scan that had to ask a model whether something looked
/// dangerous would be reviewing untrusted text with a system that reads untrusted
/// text for a living — and would give a different answer on Tuesday.
///
/// It is a screen, not a sandbox. Everything here can be worked around by someone
/// who knows it exists; its job is to make the ordinary case visible and the
/// obvious case impossible, not to certify anything.
public enum SkillScanner {
    /// Files above this are not read for patterns. A script larger than this is
    /// not a script.
    private static let readLimit = 512 * 1024
    private static let maxFiles = 2_000

    public static func scan(directory: URL) -> SkillScanReport {
        var report = SkillScanReport()

        // MARK: Structure

        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            report.findings.append(SkillFinding(
                severity: .blocked,
                title: "The folder could not be read",
                detail: "Nothing about this skill can be checked, so nothing about it can be trusted.",
                file: nil
            ))
            return report
        }

        let base = directory.standardizedFileURL.pathComponents
        var scanned: [(url: URL, relative: String, size: Int)] = []

        for case let item as URL in walker {
            let relative = Self.relative(item, from: base)
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])

            // A symlink is the classic way out of a folder you were told to stay
            // in: the link is inside, its target is not, and every later step that
            // reads "the skill's files" is reading somewhere else.
            if values?.isSymbolicLink == true {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? "?"
                report.findings.append(SkillFinding(
                    severity: .blocked,
                    title: "A link points outside the skill",
                    detail: "“\(relative)” is a symbolic link to “\(target)”. Bud installs a folder, and a link is a way to install something that is not in it.",
                    file: relative
                ))
                continue
            }
            guard values?.isRegularFile == true else { continue }

            if relative.contains("..") || relative.hasPrefix("/") {
                report.findings.append(SkillFinding(
                    severity: .blocked,
                    title: "A file name escapes the folder",
                    detail: "“\(relative)” would be written somewhere other than the skill's own directory.",
                    file: relative
                ))
                continue
            }

            report.fileCount += 1
            report.byteCount += values?.fileSize ?? 0
            scanned.append((item, relative, values?.fileSize ?? 0))
            if scanned.count >= maxFiles { break }
        }

        if report.fileCount >= maxFiles {
            report.findings.append(SkillFinding(
                severity: .caution,
                title: "A very large skill",
                detail: "Only the first \(maxFiles) files were inspected.",
                file: nil
            ))
        }
        if report.byteCount > 20_000_000 {
            report.findings.append(SkillFinding(
                severity: .caution,
                title: "An unusually large skill (\(report.byteCount / 1_000_000)MB)",
                detail: "Skills are instructions and supporting files. This much is worth a look.",
                file: nil
            ))
        }

        // MARK: Contents

        for entry in scanned {
            guard entry.size <= readLimit else {
                report.findings.append(SkillFinding(
                    severity: .caution,
                    title: "A file too large to inspect",
                    detail: "“\(entry.relative)” is \(entry.size / 1_000)KB and was not read.",
                    file: entry.relative
                ))
                continue
            }
            guard let data = FileManager.default.contents(atPath: entry.url.path) else { continue }

            let isManifest = entry.relative == "SKILL.md"
            let isInstruction = isManifest || entry.relative.lowercased().hasSuffix(".md")
            let executable = FileManager.default.isExecutableFile(atPath: entry.url.path)
                || Self.hasShebang(data)
                || Self.hasBinaryMagic(data)

            if executable {
                report.executables.append(entry.relative)
            }
            if Self.hasBinaryMagic(data) {
                report.findings.append(SkillFinding(
                    severity: .dangerous,
                    title: "A compiled program is included",
                    detail: "“\(entry.relative)” is a binary. Nothing about what it does can be read, and Bud cannot check it.",
                    file: entry.relative
                ))
            } else if executable {
                report.findings.append(SkillFinding(
                    severity: .caution,
                    title: "A runnable script",
                    detail: "“\(entry.relative)” can be executed. Skills may ship scripts, so this is normal — read it if you did not expect one.",
                    file: entry.relative
                ))
            }

            guard let text = FileReading.text(from: data) else { continue }

            if isManifest, let skill = try? SkillParser.parse(text) {
                report.declaresTools = skill.allowedTools
            }

            if isInstruction {
                Self.scanInstructions(text, file: entry.relative, into: &report)
            }
            if executable || !isInstruction {
                Self.scanCode(text, file: entry.relative, into: &report)
            }
            Self.scanUnicode(text, file: entry.relative, into: &report)
        }

        report.findings.sort { $0.severity < $1.severity }
        return report
    }

    // MARK: - Instructions

    /// What the manifest tells the model to do.
    ///
    /// This is the check that matters most and the one with no equivalent
    /// elsewhere: a skill's text is not data the model reads, it is instruction
    /// the model follows. A skill that says "do not tell the user" is not
    /// suspicious in the way a strange `curl` is — it is the whole attack.
    private static func scanInstructions(_ text: String, file: String, into report: inout SkillScanReport) {
        for rule in instructionRules {
            guard let match = rule.firstMatch(in: text) else { continue }
            report.findings.append(SkillFinding(
                severity: rule.severity,
                title: rule.title,
                detail: rule.detail + " Found: “\(match)”.",
                file: file
            ))
        }
    }

    private static let instructionRules: [Rule] = [
        Rule(
            severity: .dangerous,
            title: "Asks the model to ignore its instructions",
            detail: "Overriding what it was told is the standard opening of a prompt injection.",
            pattern: #"(ignore|disregard|forget)\s+(all\s+|any\s+|your\s+|the\s+)?(previous|prior|earlier|above|preceding)\s+(instruction|prompt|rule|direction)"#
        ),
        Rule(
            severity: .dangerous,
            title: "Asks the model to keep secrets from you",
            detail: "A skill that works for you has no reason to hide what it is doing.",
            pattern: #"(do not|don't|never)\s+(tell|inform|mention|notify|reveal|show|report)\s+(this\s+)?(to\s+)?(the\s+)?(user|human|operator)"#
        ),
        Rule(
            severity: .dangerous,
            title: "Asks the model not to ask",
            detail: "Being told to act without confirmation is how a skill does something you would have refused.",
            pattern: #"(without|never)\s+(asking|confirming|confirmation|permission|approval)"#
        ),
        Rule(
            severity: .dangerous,
            title: "Asks for the system prompt",
            detail: "Instructions to reveal or reinterpret the agent's own configuration.",
            pattern: #"(system prompt|your instructions|your configuration|reveal your|print your|repeat your)\b"#
        ),
        Rule(
            severity: .dangerous,
            title: "Asks for data to be sent somewhere",
            detail: "A skill that moves information off the machine should say so plainly, and rarely.",
            pattern: #"(exfiltrate|send|upload|post|transmit|forward)\s+(it|this|that|them|the\s+\w+|all\s+\w+)\s+(to|into)\s+(https?://|an?\s+external|a\s+remote|the\s+server)"#
        ),
        Rule(
            severity: .caution,
            title: "Mentions credentials",
            detail: "Worth reading in context: a skill may legitimately describe using a key you gave it, or be fishing for one.",
            pattern: #"(api[_ -]?key|password|secret|token|credential)s?\b"#
        ),
    ]

    // MARK: - Code

    private static func scanCode(_ text: String, file: String, into report: inout SkillScanReport) {
        for rule in codeRules {
            guard let match = rule.firstMatch(in: text) else { continue }
            report.findings.append(SkillFinding(
                severity: rule.severity,
                title: rule.title,
                detail: rule.detail + " Found: “\(match)”.",
                file: file
            ))
        }
    }

    private static let codeRules: [Rule] = [
        Rule(
            severity: .dangerous,
            title: "Deletes broadly",
            detail: "A recursive delete aimed at the machine or at your home, rather than at somewhere the skill is working. A scoped path — a build folder, the skill's own files — is not flagged.",
            // `~/Documents` counts and `/tmp/build` does not: the question is
            // whether the target is somewhere a skill has any business reaching,
            // not whether the command is recursive.
            pattern: #"rm\s+(?:-[A-Za-z-]+\s+)*-[A-Za-z]*[rR][A-Za-z]*\s+(?:~[^\s]*|\$HOME[^\s]*|/(?!tmp(?:/|\s|$))[^\s]*)"#
        ),
        Rule(
            severity: .dangerous,
            title: "Pipes a download into a shell",
            detail: "Whatever is at the other end runs with your permissions, and what it is cannot be checked from here.",
            pattern: #"(curl|wget)[^\n|]*\|\s*(sudo\s+)?(ba|z|k)?sh\b"#
        ),
        Rule(
            severity: .dangerous,
            title: "Decodes and runs something",
            detail: "Encoded payloads exist to get past exactly this kind of reading.",
            pattern: #"(base64\s+(-d|--decode)|openssl\s+enc[^\n]*)\s*\|[^\n]*(sh|bash|python|perl)"#
        ),
        Rule(
            severity: .dangerous,
            title: "Reads credentials",
            detail: "Paths holding keys and tokens. A skill has almost no reason to open them.",
            pattern: #"(\.ssh/|\.aws/|\.gnupg|id_rsa|\.netrc|\.docker/config|\.config/gh|\.kube/config|login\.keychain|security\s+find-)"#
        ),
        Rule(
            severity: .dangerous,
            title: "Runs as root",
            detail: "A skill that needs `sudo` is asking for the machine, not for a folder.",
            pattern: #"\bsudo\s+\w"#
        ),
        Rule(
            severity: .dangerous,
            title: "Runs an arbitrary string as code",
            detail: "`eval` and `exec` on anything assembled at runtime is how a harmless-looking script does something else.",
            pattern: #"\b(eval|exec)\s*\(\s*(input|sys\.argv|os\.environ|request|response|data|payload)"#
        ),
        Rule(
            severity: .caution,
            title: "Reaches the network",
            detail: "Not wrong in itself — plenty of skills fetch something — but it is where data would leave from.",
            pattern: #"(\bcurl\s|\bwget\s|\bnc\s+-|\bncat\s|socket\.socket|requests\.(get|post)|urllib\.request|http[s]?://[^\s"')]+)"#
        ),
        Rule(
            severity: .caution,
            title: "Runs a subprocess",
            detail: "Worth reading: this is how a skill reaches outside what the agent can see.",
            pattern: #"(subprocess\.(run|call|Popen|check_output)|os\.system|os\.popen|child_process)"#
        ),
    ]

    // MARK: - Unicode

    /// Text that does not read as it is written.
    ///
    /// A skill's manifest is read by a model and skimmed by a person, and those
    /// two can be shown different things: a bidirectional override reorders what
    /// is displayed without changing what is there, and zero-width characters
    /// hide words between other words.
    private static func scanUnicode(_ text: String, file: String, into report: inout SkillScanReport) {
        let suspicious: [(Character, String)] = [
            ("\u{200B}", "a zero-width space"),
            ("\u{200C}", "a zero-width non-joiner"),
            ("\u{200D}", "a zero-width joiner"),
            ("\u{202A}", "a left-to-right override"),
            ("\u{202B}", "a right-to-left override"),
            ("\u{202C}", "a directional pop"),
            ("\u{202D}", "a left-to-right isolate"),
            ("\u{202E}", "a right-to-left isolate"),
            ("\u{2066}", "a direction isolate"),
            ("\u{2067}", "a direction isolate"),
            ("\u{2068}", "a direction isolate"),
            ("\u{2069}", "a direction isolate pop"),
        ]
        let found = suspicious.filter { text.contains($0.0) }.map(\.1)
        guard !found.isEmpty else { return }
        report.findings.append(SkillFinding(
            severity: .caution,
            title: "Hidden characters",
            detail: "“\(file)” contains \(Set(found).sorted().joined(separator: ", ")). What is displayed and what is there are not always the same thing.",
            file: file
        ))
    }

    // MARK: - Helpers

    private static func hasShebang(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(64), encoding: .utf8) else { return false }
        return text.hasPrefix("#!")
    }

    /// Mach-O, ELF, or a Windows executable. The first two bytes of `0xFE 0xED`
    /// and friends, plus the universal-binary wrapper.
    private static func hasBinaryMagic(_ data: Data) -> Bool {
        let magic: [[UInt8]] = [
            [0xFE, 0xED, 0xFA, 0xCE], [0xCE, 0xFA, 0xED, 0xFE],   // Mach-O
            [0xFE, 0xED, 0xFA, 0xCF], [0xCF, 0xFA, 0xED, 0xFE],   // Mach-O 64
            [0xCA, 0xFE, 0xBA, 0xBE],                              // universal
            [0x7F, 0x45, 0x4C, 0x46],                              // ELF
            [0x4D, 0x5A],                                          // PE
        ]
        return magic.contains { data.starts(with: $0) }
    }

    private static func relative(_ item: URL, from base: [String]) -> String {
        let parts = item.standardizedFileURL.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else {
            return item.lastPathComponent
        }
        return parts.dropFirst(base.count).joined(separator: "/")
    }
}

// MARK: - Rules

private struct Rule {
    var severity: SkillFinding.Severity
    var title: String
    var detail: String
    var pattern: String

    /// The matched text, or nil. Whole-phrase patterns with word boundaries, on
    /// purpose: a rule that fired on the word "ignore" would flag every script
    /// that mentions `ignore_index`, and a screen nobody trusts is one nobody
    /// reads.
    func firstMatch(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matched = Range(match.range, in: text)
        else { return nil }
        return String(text[matched]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
