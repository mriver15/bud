import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Turning a file into something a text model can use.
///
/// `read_file` used to require UTF-8 and refuse everything else, which made a
/// dropped file a dead end for anything that was not plain text — a PDF, a
/// screenshot, a text file saved by an app that does not write UTF-8. What
/// somebody drops on an assistant is the thing they want it to look at, so the
/// job is to find whatever is legible in it rather than to report that it is not
/// a `.txt`.
public enum FileReading {
    /// What a file turned out to be, and what could be read from it.
    public enum Content {
        case text(String)
        /// Text found inside something that is not text — an image, or a PDF.
        case extracted(String, caption: String)
        case unreadable(String)
    }

    public static func read(path: String) -> Content? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let type = contentType(for: path)

        if type?.conforms(to: .pdf) == true {
            guard let text = pdfText(data: data), !text.isEmpty else {
                return .unreadable(
                    "a PDF with no text layer — it is a scan, and Bud cannot read the picture in it"
                )
            }
            return .extracted(text, caption: "text extracted from a PDF")
        }
        if type?.conforms(to: .image) == true {
            return imageContent(path: path)
        }
        if let text = text(from: data) {
            return .text(text)
        }
        // Not text by its first bytes, and not named as a PDF either. A great many
        // arrive from a browser as a bare download with no useful name at all —
        // but only a file that actually begins with the header is worth handing to
        // the parser, which logs an error for every one that is not.
        if data.starts(with: Array("%PDF".utf8)), let pdf = pdfText(data: data), !pdf.isEmpty {
            return .extracted(pdf, caption: "text extracted from a PDF")
        }
        return .unreadable(describe(data))
    }

    // MARK: - Text

    /// Text from bytes, in the encodings files actually arrive in.
    ///
    /// Latin-1 is the fallback because it cannot fail and is never wrong about
    /// *being* text: a file that is not Unicode at all is usually a single-byte
    /// encoding, and showing it with a few wrong accents is better than refusing
    /// to show it. Deciding that a file is binary first is what keeps that from
    /// being a way to dump a JPEG into the transcript.
    public static func text(from data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        if looksBinary(data) { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // UTF-16 only when it says so. The decoder is lenient enough to succeed on
        // almost any even-length byte sequence, so trying it on a Latin-1 file
        // does not fail — it produces plausible-looking nonsense and wins the
        // race against the encoding that was actually right.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Whether these bytes are something other than text.
    ///
    /// A NUL byte in the first few kilobytes is the tell: no text encoding puts
    /// one where a character belongs, and every binary format has them.
    public static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8_000)
        // A byte-order mark first: UTF-16 is full of NULs by design, and would
        // otherwise be read as binary and refused.
        if sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) { return false }
        if sample.contains(0) { return true }
        let printable = sample.filter { byte in
            byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte != 127)
        }.count
        return Double(printable) / Double(max(sample.count, 1)) < 0.85
    }

    // MARK: - PDF

    private static func pdfText(data: Data) -> String? {
        guard let document = PDFDocument(data: data) else { return nil }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 60) {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            pages.append("— page \(index + 1) —\n\(trimmed)")
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    // MARK: - Images

    private static func imageContent(path: String) -> Content {
        // Distinguished from "an image with no text": a file named as a picture
        // that cannot be opened as one is a different problem, and saying there is
        // no text in it would send someone looking for the wrong thing.
        guard let size = imageSize(path: path) else {
            return .unreadable("named as an image, but it could not be opened as one")
        }
        let dimensions = "\(Int(size.width))×\(Int(size.height))"
        guard let text = ocr(path: path), !text.isEmpty else {
            return .unreadable(
                "an image (\(dimensions)) with no text in it. Bud reads the text inside a picture; "
                    + "it cannot see the picture itself."
            )
        }
        return .extracted(
            text,
            caption: "text read from an image (\(dimensions)) — Bud reads the text in a picture, not the picture"
        )
    }

    /// Reads the text inside an image.
    ///
    /// The honest middle ground for a model with no vision: it still cannot see
    /// the screenshot, but the error message, the table, the slide and the
    /// receipt are all words, and words are what it can use.
    private static func ocr(path: String) -> String? {
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func imageSize(path: String) -> NSSize? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        return image.size
    }

    // MARK: - Everything else

    private static func contentType(for path: String) -> UTType? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)
    }

    /// What to say about a file nothing could be read from.
    ///
    /// A name is more useful than a byte count: "this is an archive" tells you
    /// what to do next, and "5000 bytes" does not.
    private static func describe(_ data: Data) -> String {
        let flavour = data.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " ")
        return "binary data (\(data.count) bytes, starts \(flavour)) — no text in it that Bud can read"
    }
}

import UniformTypeIdentifiers
