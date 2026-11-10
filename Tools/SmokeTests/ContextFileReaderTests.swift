import CoreGraphics
import CoreText
import Foundation
@testable import WhisperPilot

extension SmokeTestRunner {
    private static func makePDF(at url: URL, text: String?) {
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        pdf.beginPDFPage(nil)
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            pdf.textPosition = CGPoint(x: 20, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
        }
        pdf.endPDFPage()
        pdf.closePDF()
    }

    /// Compares everything except the per-read `id` and `attachedAt`.
    private static func sameOutcome(_ a: Result<ContextFile, ContextFileReader.ReadError>?,
                                    _ b: Result<ContextFile, ContextFileReader.ReadError>) -> Bool {
        switch (a, b) {
        case (.success(let x)?, .success(let y)):
            return x.filename == y.filename && x.sourcePath == y.sourcePath
                && x.content == y.content && x.byteCount == y.byteCount
        case (.failure(let x)?, .failure(let y)):
            return x == y
        default:
            return false
        }
    }

    private final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0
        private(set) var order: [String] = []
        private(set) var ranOnMain = false

        func enter(_ name: String) {
            lock.withLock {
                active += 1
                maxActive = max(maxActive, active)
                order.append(name)
                if Thread.isMainThread { ranOnMain = true }
            }
        }

        func leave() { lock.withLock { active -= 1 } }
    }

    @MainActor
    static func runContextFileReaderSuite() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-pilot-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sameTarget: () -> SessionID? = { nil }

        await suite("ContextFileReader: background read matches the plain read") {
            let text = dir.appendingPathComponent("notes.md")
            try? "# Agenda\nShip it".write(to: text, atomically: true, encoding: .utf8)
            let textResult = await ContextFileReader.readInBackground(text, ifTargetStays: sameTarget)
            await expect(sameOutcome(textResult, ContextFileReader.read(text)), "text file reads the same")
            if case .success(let file)? = textResult {
                await expect(file.content == "# Agenda\nShip it" && file.filename == "notes.md", "text content arrives intact")
            } else {
                await expect(false, "text file should succeed")
            }

            let unsupported = dir.appendingPathComponent("tool.exe")
            let unsupportedResult = await ContextFileReader.readInBackground(unsupported, ifTargetStays: sameTarget)
            await expect(sameOutcome(unsupportedResult, .failure(.unsupported("exe"))), "unsupported type is rejected")
            await expect(ContextFileReader.ReadError.unsupported("exe").message == "Unsupported file type .exe. Accepted: md, html, json, txt, pdf.",
                         "unsupported message is unchanged")

            let missing = dir.appendingPathComponent("gone.txt")
            let missingResult = await ContextFileReader.readInBackground(missing, ifTargetStays: sameTarget)
            await expect(sameOutcome(missingResult, .failure(.unreadable("gone.txt"))), "missing file is unreadable")
            await expect(ContextFileReader.ReadError.unreadable("gone.txt").message == "Couldn't read gone.txt — make sure it's UTF-8 text.",
                         "unreadable message is unchanged")
        }

        await suite("ContextFileReader: PDFs") {
            let pdf = dir.appendingPathComponent("brief.pdf")
            makePDF(at: pdf, text: "Quarterly budget review")
            let result = await ContextFileReader.readInBackground(pdf, ifTargetStays: sameTarget)
            await expect(sameOutcome(result, ContextFileReader.read(pdf)), "PDF reads the same")
            if case .success(let file)? = result {
                await expect(file.content.contains("Quarterly budget review"), "PDF text is extracted, got: \(file.content)")
            } else {
                await expect(false, "PDF should succeed, got \(String(describing: result))")
            }

            let blank = dir.appendingPathComponent("scan.pdf")
            makePDF(at: blank, text: nil)
            let blankResult = await ContextFileReader.readInBackground(blank, ifTargetStays: sameTarget)
            await expect(sameOutcome(blankResult, .failure(.noPDFText("scan.pdf"))), "PDF with no text is reported")
            await expect(ContextFileReader.ReadError.noPDFText("scan.pdf").message == "scan.pdf has no selectable text (it may be a scan).",
                         "no-text message is unchanged")

            let broken = dir.appendingPathComponent("broken.pdf")
            try? "not a pdf".write(to: broken, atomically: true, encoding: .utf8)
            let brokenResult = await ContextFileReader.readInBackground(broken, ifTargetStays: sameTarget)
            await expect(sameOutcome(brokenResult, .failure(.unreadable("broken.pdf"))), "broken PDF is unreadable")
        }

        await suite("ContextFileReader: drops the result when the target changed") {
            let text = dir.appendingPathComponent("late.txt")
            try? "late".write(to: text, atomically: true, encoding: .utf8)
            let before = SessionID(folderName: "before")
            let after = SessionID(folderName: "after")

            var switched: [SessionID] = [before, after]
            let stale = await ContextFileReader.readInBackground(text, ifTargetStays: { switched.removeFirst() })
            await expect(stale == nil, "session switched during the read: result is dropped")

            var loading: [SessionID?] = [before, nil]
            let midSwitch = await ContextFileReader.readInBackground(text, ifTargetStays: { loading.removeFirst() })
            await expect(midSwitch == nil, "read ends while a switch is still loading: result is dropped")

            var same: [SessionID] = [before, before]
            let kept = await ContextFileReader.readInBackground(text, ifTargetStays: { same.removeFirst() })
            await expect(sameOutcome(kept, ContextFileReader.read(text)), "same session: result is kept")
        }

        await suite("ContextFileReader: reads run off the main thread, one at a time, in order") {
            let log = ReadLog()
            let names = ["a.txt", "b.txt", "c.txt", "d.txt"]
            let tasks = names.map { name in
                Task { @MainActor in
                    await ContextFileReader.readInBackground(URL(fileURLWithPath: "/tmp/\(name)"), ifTargetStays: sameTarget) { url in
                        log.enter(url.lastPathComponent)
                        Thread.sleep(forTimeInterval: 0.02)
                        log.leave()
                        return .failure(.unreadable(url.lastPathComponent))
                    }
                }
            }
            for task in tasks { _ = await task.value }
            await expect(!log.ranOnMain, "reads never run on the main thread")
            await expect(log.maxActive == 1, "only one read runs at a time, saw \(log.maxActive)")
            await expect(log.order == names, "reads run in the order they were asked for, got \(log.order)")
        }
    }
}
