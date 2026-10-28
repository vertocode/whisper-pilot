import Foundation
import PDFKit

/// Turns a file the user picked into text for `ContextFile`. Plain-text formats are read as
/// UTF-8; PDFs go through PDFKit's text extraction.
enum ContextFileReader {
    static let textExtensions: Set<String> = ["md", "markdown", "html", "htm", "json", "txt", "text"]
    static let acceptedExtensions: Set<String> = textExtensions.union(["pdf"])
    static let acceptedList = "md, html, json, txt, pdf"

    enum ReadError: Error, Equatable {
        case unsupported(String)
        case unreadable(String)
        case noPDFText(String)

        var message: String {
            switch self {
            case .unsupported(let ext): return "Unsupported file type .\(ext). Accepted: \(ContextFileReader.acceptedList)."
            case .unreadable(let name): return "Couldn't read \(name) — make sure it's UTF-8 text."
            case .noPDFText(let name): return "\(name) has no selectable text (it may be a scan)."
            }
        }
    }

    static func read(_ url: URL) -> Result<ContextFile, ReadError> {
        let ext = url.pathExtension.lowercased()
        guard acceptedExtensions.contains(ext) else { return .failure(.unsupported(ext)) }
        let name = url.lastPathComponent
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }

        let raw: String
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return .failure(.unreadable(name)) }
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.noPDFText(name)) }
            raw = text
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return .failure(.unreadable(name))
            }
            raw = text
        }
        let content = truncated(raw)
        return .success(ContextFile(
            id: UUID(),
            filename: name,
            sourcePath: url.path,
            content: content,
            byteCount: content.utf8.count,
            attachedAt: Date()
        ))
    }

    static func truncated(_ raw: String) -> String {
        guard raw.utf8.count > SessionContext.maxFileBytes else { return raw }
        return String(raw.prefix(SessionContext.maxFileBytes)) + "\n\n…[truncated, file is larger than 200 KB]"
    }
}
