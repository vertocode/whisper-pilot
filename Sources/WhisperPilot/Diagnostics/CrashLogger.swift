import Darwin
import Foundation

/// Persistent log + crash detector.
///
/// Whisper Pilot runs as an accessory app (`LSUIElement = true`), so a hard
/// crash doesn't surface a Cocoa dialog — the app just disappears. Without
/// persistent logging the user has nothing to look at after the fact, and the
/// in-memory `LogBuffer` is lost as soon as the process dies. This class:
///
/// 1. Mirrors every `wpInfo / wpWarn / wpError` line into a rolling log file
///    at `~/Library/Application Support/<bundle>/runtime.log`.
/// 2. Drops a `clean-shutdown` sentinel file at launch and removes it on
///    `applicationWillTerminate`. Sentinel still present on next launch ⇒
///    last run terminated unexpectedly.
/// 3. Installs `NSSetUncaughtExceptionHandler` and POSIX signal handlers so
///    catastrophic failures (SIGSEGV, SIGABRT, fatalError) get a final line
///    written before the process exits.
/// 4. Subscribes to memory-pressure events so out-of-memory kills show up in
///    the log immediately before they happen.
///
/// `start()` is called from `applicationDidFinishLaunching`, which means the
/// crash handlers themselves don't catch a crash that happens during very
/// early process startup. That's an acceptable trade — early-startup crashes
/// are extremely rare in practice and would surface in macOS's own
/// `~/Library/Logs/DiagnosticReports/` regardless.
final class CrashLogger: @unchecked Sendable {
    static let shared = CrashLogger()

    private let logURL: URL
    private let sentinelURL: URL
    /// Writes happen on a serial queue so concurrent `writeLine` calls don't
    /// interleave bytes mid-line in the file. The signal-handler path bypasses
    /// the queue (you can't `dispatch_async` from a signal handler) and writes
    /// directly with the raw FD.
    private let queue = DispatchQueue(label: "com.whisperpilot.crashlog", qos: .utility)
    /// `FileHandle` retains the underlying file descriptor for the lifetime of
    /// the process — we hold it as a property so the fd stays open and `write(2)`
    /// keeps working from the signal handler (which can't safely re-open files).
    /// We can't use `Darwin.open` directly because Swift refuses to import the
    /// variadic C form (`open(_:_:_:)`), so `FileHandle` is the simplest way to
    /// get a raw fd we control.
    private var fileHandle: FileHandle?
    private var fileDescriptor: Int32 = -1
    private var memorySource: DispatchSourceMemoryPressure?
    /// Static copy of the fd for the C-function signal handlers — they can't
    /// capture `self`. Set in `start()`. -1 means "logger not started yet".
    fileprivate static var signalFD: Int32 = -1

    private init() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.whisperpilot.app"
        let base: URL
        if let url = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = url.appendingPathComponent(bundleId)
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(bundleId)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.logURL = base.appendingPathComponent("runtime.log")
        self.sentinelURL = base.appendingPathComponent("clean-shutdown")
    }

    var logFilePath: String { logURL.path }

    func start() {
        // Trim the log if it's gotten huge. Truncate to last 256 KB so we keep
        // the most recent activity — the data immediately preceding a crash is
        // what's actually useful.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            truncateToTail(bytes: 256_000)
        }

        // Ensure the file exists, then open a FileHandle and pull its raw fd.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            // `seekToEnd` is what makes subsequent writes append rather than
            // overwriting the file's existing content. We don't care about
            // the return value (the new offset) — only the side effect.
            _ = try? handle.seekToEnd()
            fileHandle = handle
            fileDescriptor = handle.fileDescriptor
            Self.signalFD = fileDescriptor
        }

        writeLine("=== Whisper Pilot launched (pid \(getpid())) ===")
        // Sentinel is the "running" mark — its presence on next launch means
        // we never reached `applicationWillTerminate`.
        try? "running".write(to: sentinelURL, atomically: true, encoding: .utf8)

        // Catch ObjC / NSException-style crashes (e.g. unrecognized selector).
        NSSetUncaughtExceptionHandler { exception in
            CrashLogger.shared.handleUncaughtException(exception)
        }

        // Catch fatal POSIX signals. SIGABRT is what Swift's `fatalError` and
        // optional-unwrap-of-nil raise — these are the most common Swift-side
        // hard crashes.
        for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE] as [Int32] {
            signal(sig, crashLogger_signalHandler)
        }

        // Memory pressure: when macOS is about to OOM-kill us, we get a warning
        // (and then critical). Logging it gives the user a concrete cause when
        // the next launch reports "previous run terminated unexpectedly".
        let mem = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        mem.setEventHandler { [weak mem] in
            guard let mem else { return }
            let event = mem.data
            let label: String
            if event.contains(.critical) {
                label = "CRITICAL — process likely to be terminated by the kernel"
            } else if event.contains(.warning) {
                label = "warning — system under pressure"
            } else {
                label = "normal"
            }
            CrashLogger.shared.writeLine("⚠️ memory pressure: \(label)")
        }
        mem.resume()
        memorySource = mem
    }

    /// Mark a clean shutdown so the next launch knows we exited deliberately.
    /// Must be called from `applicationWillTerminate`.
    func markCleanShutdown() {
        writeLine("=== clean shutdown ===")
        // Best-effort close via FileHandle; ignore errors. The OS reaps the fd
        // anyway, but explicitly closing flushes the kernel buffer first.
        try? fileHandle?.close()
        fileHandle = nil
        fileDescriptor = -1
        Self.signalFD = -1
        try? FileManager.default.removeItem(at: sentinelURL)
    }

    /// `true` iff the previous run never reached `markCleanShutdown()` —
    /// either it crashed, was killed by the kernel (OOM), or was force-quit.
    func wasLastRunUnclean() -> Bool {
        FileManager.default.fileExists(atPath: sentinelURL.path)
    }

    /// Returns the tail of the current log file. Used on relaunch to populate
    /// the in-app diagnostics panel with the previous run's last activity, so
    /// the user has *something* to share when reporting a crash.
    func logTail(bytes: Int = 16_384) -> String? {
        guard let data = try? Data(contentsOf: logURL) else { return nil }
        let tail = data.suffix(bytes)
        return String(data: tail, encoding: .utf8)
    }

    /// Append one line. Cheap and non-blocking — the actual write hits the file
    /// on the logger's serial queue.
    func writeLine(_ message: String) {
        queue.async { [self] in
            guard fileDescriptor >= 0 else { return }
            let timestamp = Self.timestampFormatter.string(from: Date())
            let line = "\(timestamp) \(message)\n"
            line.withCString { ptr in
                _ = Darwin.write(fileDescriptor, ptr, strlen(ptr))
            }
        }
    }

    fileprivate func handleUncaughtException(_ exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n  ")
        let line = "=== UNCAUGHT EXCEPTION === \(exception.name.rawValue): \(exception.reason ?? "(no reason)")\nStack:\n  \(stack)\n"
        // Write synchronously — the process is about to die, the queue won't
        // get a chance to drain.
        if fileDescriptor >= 0 {
            line.withCString { ptr in
                _ = Darwin.write(fileDescriptor, ptr, strlen(ptr))
            }
        }
    }

    /// Used by `start()` to roll over an oversized log without losing the most
    /// recent activity. Simpler than incremental rotation: read the tail, blow
    /// away the file, write the tail back.
    private func truncateToTail(bytes: Int) {
        guard let data = try? Data(contentsOf: logURL) else { return }
        let tail = data.suffix(bytes)
        try? tail.write(to: logURL, options: .atomic)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Top-level C function signal handler. Must be async-signal-safe — no
/// allocations, no Swift runtime calls, no Foundation. We're limited to `write`
/// and `_exit`. The string we write is a literal, so its bytes are reachable
/// without going through Swift's string machinery.
private func crashLogger_signalHandler(_ signalNumber: Int32) {
    let fd = CrashLogger.signalFD
    if fd >= 0 {
        // Pick the literal at the call site so we don't have to format anything.
        let msg: StaticString
        switch signalNumber {
        case SIGSEGV: msg = "=== CRASH: SIGSEGV ===\n"
        case SIGABRT: msg = "=== CRASH: SIGABRT (Swift fatalError or assertion) ===\n"
        case SIGBUS:  msg = "=== CRASH: SIGBUS ===\n"
        case SIGILL:  msg = "=== CRASH: SIGILL ===\n"
        case SIGFPE:  msg = "=== CRASH: SIGFPE ===\n"
        default:      msg = "=== CRASH: signal ===\n"
        }
        msg.withUTF8Buffer { buf in
            _ = Darwin.write(fd, buf.baseAddress, buf.count)
        }
    }
    // Re-raise with the default handler so the OS still writes its own crash
    // report into ~/Library/Logs/DiagnosticReports/.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
