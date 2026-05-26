import AppKit
import Carbon.HIToolbox
import Foundation

/// Wraps the Carbon `RegisterEventHotKey` API so a single global key combo can
/// fire a handler from anywhere in the system — including when Whisper Pilot
/// isn't the frontmost app, and including when the overlay has click-through on
/// (which makes the window itself unreachable via the mouse).
///
/// Why Carbon and not `NSEvent.addGlobalMonitorForEvents`?
/// - `NSEvent` global monitors require Accessibility permission since macOS
///   Mojave for any non-trivial key listening, and they only *observe* — they
///   can't consume the event, so the combo also reaches whatever app is
///   frontmost.
/// - `RegisterEventHotKey` needs no special permission, properly suppresses
///   the event from the frontmost app, and is what every well-behaved system
///   utility (Alfred, Raycast, etc.) uses for app-level shortcuts.
final class GlobalHotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    private let onFire: @MainActor () -> Void

    // The Carbon hotkey handler fires on whatever thread Carbon picks, so the
    // registry isn't main-actor-bound. A lock keeps `instances` consistent
    // between init, deinit, and the static event handler. `onFire` itself
    // hops back to MainActor before invoking the caller's closure so callers
    // don't have to think about threading.
    private static let lock = NSLock()
    private static var nextID: UInt32 = 1
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var handlerInstalled = false

    /// Registers `keyCode` + `modifiers` (NSEvent-format modifier mask) and
    /// invokes `onFire` on the main thread every time the combo fires. Returns
    /// nil if registration failed — typically because another app has already
    /// claimed the same combo.
    init?(keyCode: UInt16, nsModifiers: UInt, onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
        Self.lock.lock()
        self.id = Self.nextID
        Self.nextID += 1
        Self.lock.unlock()

        Self.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            Self.carbonModifiers(from: NSEvent.ModifierFlags(rawValue: nsModifiers)),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            wpWarn("GlobalHotKey: RegisterEventHotKey failed (status=\(status), keyCode=\(keyCode)) — combo may already be in use by another app")
            return nil
        }
        self.hotKeyRef = ref
        Self.lock.lock()
        Self.instances[id] = self
        Self.lock.unlock()
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.lock.lock()
        Self.instances.removeValue(forKey: id)
        Self.lock.unlock()
    }

    // MARK: - Carbon glue

    /// `OSType` 'WPHK' — identifies our hotkey events in the shared handler
    /// so we don't dispatch on events posted by other event sources that
    /// happen to share the same application target.
    private static let signature: OSType = {
        let bytes: [UInt8] = Array("WPHK".utf8)
        return (OSType(bytes[0]) << 24) | (OSType(bytes[1]) << 16) | (OSType(bytes[2]) << 8) | OSType(bytes[3])
    }()

    private static func installHandlerIfNeeded() {
        lock.lock()
        let already = handlerInstalled
        if !already { handlerInstalled = true }
        lock.unlock()
        guard !already else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, _ in
                guard let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let res = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard res == noErr, hotKeyID.signature == GlobalHotKey.signature else { return res }
                let id = hotKeyID.id
                GlobalHotKey.lock.lock()
                let instance = GlobalHotKey.instances[id]
                GlobalHotKey.lock.unlock()
                if let instance {
                    let fire = instance.onFire
                    Task { @MainActor in fire() }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
        if status != noErr {
            wpWarn("GlobalHotKey: InstallEventHandler failed (status=\(status)) — global hotkeys won't fire")
            lock.lock()
            handlerInstalled = false
            lock.unlock()
        }
    }

    /// NSEvent and Carbon use completely different bit positions for modifier
    /// flags. NSEvent puts Command at bit 20; Carbon puts it at bit 8. This
    /// converts a device-independent NSEvent mask into the Carbon mask
    /// `RegisterEventHotKey` expects.
    private static func carbonModifiers(from nsFlags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if nsFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if nsFlags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if nsFlags.contains(.option)  { carbon |= UInt32(optionKey) }
        if nsFlags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}
