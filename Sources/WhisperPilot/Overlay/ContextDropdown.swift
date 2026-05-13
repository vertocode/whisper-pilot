import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Collapsible attach-context panel used in two places:
///
/// 1. The AI lane inside `OverlayView` — bound to the active session's context.
/// 2. The Sessions home page — bound to the *global* context that applies to
///    every session.
///
/// Behaviour is identical in both spots; only the parent's binding differs. Persistence
/// is the caller's responsibility — this view just mutates the binding.
struct ContextDropdown: View {
    @Binding var context: SessionContext
    /// Copy shown next to the "Context" header chevron when the panel is collapsed
    /// and the context has content (e.g. "3 chars of notes, 1 file"). Owner can pass
    /// a custom label/explainer above the panel; this is internal-only.
    var title: String = "Context"
    /// Optional extra body rendered below the drop zone (e.g. the global-context
    /// "this applies to every session" warning). `nil` for the per-session panel.
    var footer: AnyView? = nil
    /// When provided, the panel renders this above the notes editor. Used by the
    /// global panel to surface its token-cost warning right where the user is
    /// about to type something.
    var notice: AnyView? = nil

    @State private var isExpanded: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var lastError: String?

    /// File types we accept via drag-drop and the open panel. Plain text covers
    /// `.txt` and most code files; markdown / html / json are called out explicitly
    /// so the picker doesn't dim them when parent type-conformance is fuzzy.
    private static let acceptedExtensions: Set<String> = ["md", "markdown", "html", "htm", "json", "txt", "text"]
    private static let acceptedTypes: [UTType] = [
        .plainText, .text, .json, .html,
        UTType(filenameExtension: "md") ?? .plainText
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: WP.Space.xs) {
            header
            if isExpanded {
                expandedBody
            }
        }
        .padding(WP.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                .fill(.quinary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var header: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
            HStack(spacing: WP.Space.xs) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(WP.TextStyle.sectionHeader)
                    .foregroundStyle(.secondary)
                if !context.isEmpty {
                    Text(summary)
                        .font(WP.TextStyle.tag)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var summary: String {
        var parts: [String] = []
        let notesChars = context.customText.trimmingCharacters(in: .whitespacesAndNewlines).count
        if notesChars > 0 { parts.append("\(notesChars) chars of notes") }
        if !context.files.isEmpty {
            parts.append("\(context.files.count) file\(context.files.count == 1 ? "" : "s")")
        }
        return "· " + parts.joined(separator: ", ")
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: WP.Space.sm) {
            if let notice {
                notice
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Notes")
                    .font(WP.TextStyle.micro)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $context.customText)
                    .font(WP.TextStyle.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 140)
                    .padding(WP.Space.xs)
                    .background(
                        RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                            .fill(.background.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }

            if !context.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attached files")
                        .font(WP.TextStyle.micro)
                        .foregroundStyle(.tertiary)
                    ForEach(context.files) { file in
                        attachedFileRow(file)
                    }
                }
            }

            dropZone

            if let lastError {
                Text(lastError)
                    .font(WP.TextStyle.micro)
                    .foregroundStyle(.orange)
            }

            if let footer {
                footer
            }
        }
    }

    private func attachedFileRow(_ file: ContextFile) -> some View {
        HStack(spacing: WP.Space.xs) {
            Image(systemName: fileIcon(for: file.filename))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.filename)
                    .font(WP.TextStyle.body)
                Text("\(formattedSize(file.byteCount)) · \(file.sourcePath)")
                    .font(WP.TextStyle.micro)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                context.files.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, WP.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                .fill(.background.opacity(0.4))
        )
    }

    private var dropZone: some View {
        HStack(spacing: WP.Space.sm) {
            Button(action: pickFiles) {
                HStack(spacing: WP.Space.xs) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add file")
                        .font(WP.TextStyle.micro)
                }
                .chip(.neutral)
            }
            .buttonStyle(.plain)

            Text(isDropTargeted ? "Drop to attach" : "or drag & drop .md / .html / .json / .txt")
                .font(WP.TextStyle.micro)
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, WP.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WP.Radius.sm, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 0.75, dash: [4, 3])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: - File handling

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.acceptedTypes
        panel.title = "Attach context files"
        panel.message = "Pick .md, .html, .json, or .txt files to include in AI prompts."
        if panel.runModal() == .OK {
            for url in panel.urls { attach(url) }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { attach(url) }
            }
        }
    }

    private func attach(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard Self.acceptedExtensions.contains(ext) else {
            lastError = "Unsupported file type .\(ext). Accepted: md, html, json, txt."
            return
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            lastError = "Couldn't read \(url.lastPathComponent) — make sure it's UTF-8 text."
            return
        }
        let truncated: String
        if raw.utf8.count > SessionContext.maxFileBytes {
            let limited = String(raw.prefix(SessionContext.maxFileBytes))
            truncated = limited + "\n\n…[truncated, file is larger than 200 KB]"
        } else {
            truncated = raw
        }
        let file = ContextFile(
            id: UUID(),
            filename: url.lastPathComponent,
            sourcePath: url.path,
            content: truncated,
            byteCount: truncated.utf8.count,
            attachedAt: Date()
        )
        if let existingIndex = context.files.firstIndex(where: { $0.sourcePath == file.sourcePath }) {
            context.files[existingIndex] = file
        } else {
            context.files.append(file)
        }
        lastError = nil
    }

    private func fileIcon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "doc.text"
        case "html", "htm":    return "globe"
        case "json":           return "curlybraces.square"
        default:               return "doc"
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
