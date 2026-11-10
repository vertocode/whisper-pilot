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

    /// One read at a time, so attaching several big PDFs can't pile up CPU and memory during a meeting.
    private static let readQueue = DispatchQueue(
        label: "com.whisperpilot.context-file-reader",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    /// Runs `read` away from the main thread, because a large PDF can take long enough to stall
    /// the overlay and live captions. Returns `nil` if `currentTarget` changed during the read:
    /// the user has moved on, so the file must not land in whatever is open now.
    @MainActor
    static func readInBackground(
        _ url: URL,
        ifTargetStays currentTarget: () -> SessionID?,
        reader: @escaping @Sendable (URL) -> Result<ContextFile, ReadError> = { read($0) }
    ) async -> Result<ContextFile, ReadError>? {
        let target = currentTarget()
        let result: Result<ContextFile, ReadError> = await withCheckedContinuation { continuation in
            readQueue.async { continuation.resume(returning: reader(url)) }
        }
        return currentTarget() == target ? result : nil
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
            let text = joinedPageText(pageCount: document.pageCount) { document.page(at: $0)?.string }
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Stops once past the size limit, because `truncated` would cut the rest anyway and pulling
    /// the text of a huge PDF can push memory over the resource limit that pauses the mic.
    /// Counts characters, not bytes, because characters are what `truncated` keeps. Over-limit
    /// text is re-checked trimmed so the file still gets its truncation marker after `read` trims it.
    static func joinedPageText(pageCount: Int, pageText: (Int) -> String?) -> String {
        var text = ""
        var characters = 0
        for index in 0..<pageCount {
            autoreleasepool {
                guard let page = pageText(index), !page.isEmpty else { return }
                text += page + "\n"
                characters += page.count + 1
            }
            if characters > SessionContext.maxFileBytes,
               text.trimmingCharacters(in: .whitespacesAndNewlines).count > SessionContext.maxFileBytes {
                break
            }
        }
        return text
    }

    static func truncated(_ raw: String) -> String {
        guard raw.utf8.count > SessionContext.maxFileBytes else { return raw }
        return String(raw.prefix(SessionContext.maxFileBytes)) + "\n\n…[truncated, file is larger than 200 KB]"
    }
}
