import AVFoundation
import Foundation
import Speech
@testable import WhisperPilot

/// In-memory stand-in for the Keychain. Records every secret read so tests can
/// prove the app opens a secret only when it should.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private var build: String
    private var readLog: [String] = []
    private var setCalls = 0
    private var overrides: [String: KeychainHelper.ReadResult] = [:]
    private var writeStatus: OSStatus = errSecSuccess

    init(items: [String: String] = [:], build: String = "build-1") {
        self.items = items
        self.build = build
    }

    var buildIdentity: String { lock.withLock { build } }
    var reads: [String] { lock.withLock { readLog } }
    var setCount: Int { lock.withLock { setCalls } }
    func item(_ key: String) -> String? { lock.withLock { items[key] } }
    func setBuild(_ value: String) { lock.withLock { build = value } }
    func failReads(of key: String, with result: KeychainHelper.ReadResult?) { lock.withLock { overrides[key] = result } }
    func failWrites(with status: OSStatus) { lock.withLock { writeStatus = status } }

    func exists(_ key: String) -> Bool { lock.withLock { items[key] != nil } }

    func read(_ key: String) -> KeychainHelper.ReadResult {
        lock.withLock {
            readLog.append(key)
            if let forced = overrides[key] { return forced }
            return items[key].map(KeychainHelper.ReadResult.value) ?? .notFound
        }
    }

    func set(_ value: String?, forKey key: String) -> OSStatus {
        lock.withLock {
            setCalls += 1
            guard writeStatus == errSecSuccess else { return writeStatus }
            if let value, !value.isEmpty { items[key] = value } else { items[key] = nil }
            return errSecSuccess
        }
    }
}

extension SmokeTestRunner {
    private static func bundleJSON(gemini: String? = nil, anthropic: String? = nil) -> String {
        var dict: [String: String] = [:]
        if let gemini { dict["gemini"] = gemini }
        if let anthropic { dict["anthropic"] = anthropic }
        return String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    private static func bundleContents(_ fake: FakeSecretStore) -> [String: String]? {
        guard let json = fake.item("api_keys"),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] else { return nil }
        return object
    }

    private static func scratchDefaults() -> UserDefaults {
        let name = "wp-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func runKeychainSuite() async {
        await suite("Keychain: launch never reads a secret") { await keychainLaunchScenarios() }
        await suite("Keychain: unlock, approval and denial") { await keychainUnlockScenarios() }
        await suite("Keychain: legacy items move into one bundle") { await keychainMigrationScenarios() }
        await suite("Keychain: saving and removing keys") { await keychainSaveScenarios() }
        await suite("Keychain: error wording") {
            await expect(KeychainHelper.describe(errSecAuthFailed).contains("did not allow"), "auth failure -> macOS did not allow access")
            await expect(KeychainHelper.describe(errSecNotAvailable).contains("not available"), "no keychain -> not available")
            await expect(KeychainHelper.describe(errSecReadOnly).contains("read-only"), "read-only keychain is named")
        }
    }

    @MainActor
    private static func keychainLaunchScenarios() async {
        // Fresh install: nothing stored, nothing read.
        let fresh = FakeSecretStore()
        let freshStore = SettingsStore(defaults: scratchDefaults(), secrets: fresh)
        await expect(freshStore.keychainAccess == .noKeysStored, "fresh install has no keys to unlock")
        await expect(fresh.reads.isEmpty && fresh.setCount == 0, "fresh install touches no secret")
        await expect(freshStore.availableVendors.isEmpty, "no vendor is available without a key")

        // Key saved, but this build was never approved: must not read at launch.
        let saved = FakeSecretStore(items: ["api_keys": bundleJSON(gemini: "g-key")])
        let store = SettingsStore(defaults: scratchDefaults(), secrets: saved)
        await expect(store.keychainAccess == .needsUnlock, "unapproved build starts locked")
        await expect(saved.reads.isEmpty, "launch does not read the secret of an unapproved build")
        await expect(store.geminiAPIKey == nil, "a locked key is not available to the app")
        await expect(store.hasGeminiAPIKey && store.hasAnthropicAPIKey, "vendors are assumed present while locked")
        _ = store.availableVendors
        await expect(saved.reads.isEmpty, "asking which vendors exist never reads a secret")

        // Saving while locked would raise the dialog, so it is refused.
        store.geminiAPIKey = "other"
        await expect(saved.setCount == 0, "saving while locked writes nothing")
        await expect(store.keychainErrorMessage?.contains("isn't unlocked") == true, "saving while locked explains why")
        await expect(bundleContents(saved)?["gemini"] == "g-key", "the stored key is unchanged")
    }

    @MainActor
    private static func keychainUnlockScenarios() async {
        let defaults = scratchDefaults()
        let fake = FakeSecretStore(items: ["api_keys": bundleJSON(gemini: "g-key")])
        let store = SettingsStore(defaults: defaults, secrets: fake)

        let access = await store.unlockStoredKeys()
        await expect(access == .ready && store.keychainAccess == .ready, "unlock opens the saved keys")
        await expect(store.geminiAPIKey == "g-key" && store.anthropicAPIKey == nil, "only the saved vendor has a key")
        await expect(fake.reads == ["api_keys"], "unlock reads the single bundle item once")
        await expect(store.availableVendors == [.gemini], "available vendors follow the unlocked keys")

        // The approval is remembered for this build, so the next launch opens it without asking.
        let relaunched = SettingsStore(defaults: defaults, secrets: fake)
        await expect(relaunched.keychainAccess == .ready && relaunched.geminiAPIKey == "g-key", "an approved build opens its keys at launch")
        await expect(fake.reads == ["api_keys", "api_keys"], "the approved launch reads exactly once")

        // A new build (new signature) must ask again, without reading first.
        fake.setBuild("build-2")
        let readsBefore = fake.reads.count
        let updated = SettingsStore(defaults: defaults, secrets: fake)
        await expect(updated.keychainAccess == .needsUnlock, "a new build starts locked again")
        await expect(fake.reads.count == readsBefore, "a new build reads nothing until the user allows it")

        // An unreadable signature never counts as approved.
        fake.setBuild(KeychainHelper.unknownBuildIdentity)
        let unknown = SettingsStore(defaults: defaults, secrets: fake)
        await expect(unknown.keychainAccess == .needsUnlock, "an unknown build identity always asks")

        // Deferring setup is remembered per build only.
        let deferDefaults = scratchDefaults()
        let deferStore = SettingsStore(defaults: deferDefaults, secrets: FakeSecretStore(build: "build-1"))
        await expect(!deferStore.isSetupDeferredForThisBuild, "setup is not deferred by default")
        deferStore.deferSetupForThisBuild()
        await expect(deferStore.isSetupDeferredForThisBuild, "Set up later is remembered")
        let nextBuild = SettingsStore(defaults: deferDefaults, secrets: FakeSecretStore(build: "build-2"))
        await expect(!nextBuild.isSetupDeferredForThisBuild, "Set up later does not carry over to an updated build")

        // Denied, then allowed on retry.
        let deniedFake = FakeSecretStore(items: ["api_keys": bundleJSON(gemini: "g-key")])
        deniedFake.failReads(of: "api_keys", with: .denied)
        let deniedStore = SettingsStore(defaults: scratchDefaults(), secrets: deniedFake)
        let denied = await deniedStore.unlockStoredKeys()
        await expect(denied == .denied && deniedStore.geminiAPIKey == nil, "a refused read leaves the keys locked")
        await expect(deniedStore.keychainErrorMessage?.contains("Allow Keychain access") == true, "a refusal tells the user what to press")
        deniedFake.failReads(of: "api_keys", with: nil)
        let retried = await deniedStore.unlockStoredKeys()
        await expect(retried == .ready && deniedStore.geminiAPIKey == "g-key", "a retry after allowing works")
        await expect(deniedStore.keychainErrorMessage == nil, "the error clears after a successful retry")

        // Other Keychain failures and a damaged item.
        let failedFake = FakeSecretStore(items: ["api_keys": bundleJSON(gemini: "g")])
        failedFake.failReads(of: "api_keys", with: .failed(errSecNotAvailable))
        let failedStore = SettingsStore(defaults: scratchDefaults(), secrets: failedFake)
        _ = await failedStore.unlockStoredKeys()
        await expect(failedStore.keychainAccess == .denied, "a failed read keeps the keys locked")
        await expect(failedStore.keychainErrorMessage?.contains("Could not read") == true, "a failed read explains itself")

        let damaged = FakeSecretStore(items: ["api_keys": "not json"])
        let damagedStore = SettingsStore(defaults: scratchDefaults(), secrets: damaged)
        _ = await damagedStore.unlockStoredKeys()
        await expect(damagedStore.keychainAccess == .denied && damagedStore.keychainErrorMessage?.contains("damaged") == true, "a damaged bundle is reported as damaged")
    }

    @MainActor
    private static func keychainMigrationScenarios() async {
        let defaults = scratchDefaults()
        let fake = FakeSecretStore(items: ["gemini.api_key": "g", "anthropic.api_key": "a"])
        let store = SettingsStore(defaults: defaults, secrets: fake)
        await expect(store.keychainAccess == .needsUnlock, "legacy items start locked")
        await expect(store.availableVendors == [.gemini, .anthropic], "legacy items still count as configured vendors")
        await expect(fake.reads.isEmpty, "legacy items are not read at launch")

        _ = await store.unlockStoredKeys()
        await expect(store.keychainAccess == .ready && store.geminiAPIKey == "g" && store.anthropicAPIKey == "a", "unlock reads both legacy keys")
        await expect(fake.reads == ["gemini.api_key", "anthropic.api_key"], "each legacy item is read once")
        await expect(bundleContents(fake) == ["gemini": "g", "anthropic": "a"], "both keys are written into the single bundle")
        await expect(fake.item("gemini.api_key") == "g" && fake.item("anthropic.api_key") == "a", "legacy items are left in place")

        let relaunched = SettingsStore(defaults: defaults, secrets: fake)
        await expect(relaunched.geminiAPIKey == "g" && relaunched.anthropicAPIKey == "a", "after migration the bundle supplies the keys")
        await expect(Array(fake.reads.suffix(1)) == ["api_keys"], "after migration only the bundle is read")
        await expect(fake.reads.filter { $0 == "gemini.api_key" }.count == 1, "legacy items are not read a second time")

        // The move into the bundle fails: keys still work, and the move is retried next launch.
        let retryDefaults = scratchDefaults()
        let readOnly = FakeSecretStore(items: ["gemini.api_key": "g"])
        readOnly.failWrites(with: errSecReadOnly)
        let first = SettingsStore(defaults: retryDefaults, secrets: readOnly)
        _ = await first.unlockStoredKeys()
        await expect(first.keychainAccess == .ready && first.geminiAPIKey == "g", "keys work for this run even if the bundle write fails")
        await expect(readOnly.item("api_keys") == nil, "nothing was written to the bundle")
        readOnly.failWrites(with: errSecSuccess)
        _ = SettingsStore(defaults: retryDefaults, secrets: readOnly)
        await expect(bundleContents(readOnly) == ["gemini": "g"], "the next launch finishes the move")
        await expect(readOnly.reads.filter { $0 == "gemini.api_key" }.count == 2, "the legacy item was read again for the retry")

        // A refused legacy read stops at the first item.
        let refused = FakeSecretStore(items: ["gemini.api_key": "g", "anthropic.api_key": "a"])
        refused.failReads(of: "gemini.api_key", with: .denied)
        let refusedStore = SettingsStore(defaults: scratchDefaults(), secrets: refused)
        _ = await refusedStore.unlockStoredKeys()
        await expect(refusedStore.keychainAccess == .denied && refused.item("api_keys") == nil, "a refused legacy read writes nothing")
        await expect(refused.reads == ["gemini.api_key"], "a refusal stops before more dialogs can stack")
    }

    @MainActor
    private static func keychainSaveScenarios() async {
        // First key on a fresh install: allowed without unlocking, and remembered as approved.
        let defaults = scratchDefaults()
        let fake = FakeSecretStore()
        let store = SettingsStore(defaults: defaults, secrets: fake)
        store.geminiAPIKey = "g-key"
        await expect(store.keychainAccess == .ready && store.geminiAPIKey == "g-key", "the first saved key is usable at once")
        await expect(bundleContents(fake) == ["gemini": "g-key"], "the key is stored in the bundle item")
        await expect(fake.reads.isEmpty, "saving reads no secret")
        let relaunched = SettingsStore(defaults: defaults, secrets: fake)
        await expect(relaunched.keychainAccess == .ready && relaunched.geminiAPIKey == "g-key", "a saved key is available at the next launch")

        // Add, replace and remove keys.
        store.anthropicAPIKey = "a-key"
        await expect(bundleContents(fake) == ["gemini": "g-key", "anthropic": "a-key"], "a second vendor joins the same bundle")
        store.geminiAPIKey = nil
        await expect(bundleContents(fake) == ["anthropic": "a-key"] && store.geminiAPIKey == nil, "removing one vendor keeps the other")
        store.anthropicAPIKey = ""
        await expect(fake.item("api_keys") == nil && store.keychainAccess == .noKeysStored, "removing the last key deletes the item")

        // A failed write changes nothing and says why.
        store.geminiAPIKey = "old"
        fake.failWrites(with: errSecReadOnly)
        store.geminiAPIKey = "new"
        await expect(store.geminiAPIKey == "old", "a failed save keeps the previous key")
        await expect(store.keychainErrorMessage?.contains("read-only") == true, "a failed save names the reason")
        fake.failWrites(with: errSecSuccess)
        store.geminiAPIKey = "new"
        await expect(store.geminiAPIKey == "new" && store.keychainErrorMessage == nil, "saving works again and the error clears")
    }

    static func runPermissionMappingSuite() async {
        await suite("Permission status mapping") {
            await expect(PermissionMapping.microphone(.authorized) == .granted, "microphone authorized -> granted")
            await expect(PermissionMapping.microphone(.denied) == .denied, "microphone denied -> denied")
            await expect(PermissionMapping.microphone(.restricted) == .denied, "microphone restricted -> denied")
            await expect(PermissionMapping.microphone(.notDetermined) == .unknown, "microphone not asked -> unknown")
            await expect(PermissionMapping.speechRecognition(.authorized) == .granted, "speech authorized -> granted")
            await expect(PermissionMapping.speechRecognition(.denied) == .denied, "speech denied -> denied")
            await expect(PermissionMapping.speechRecognition(.restricted) == .denied, "speech restricted -> denied")
            await expect(PermissionMapping.speechRecognition(.notDetermined) == .unknown, "speech not asked -> unknown")

            await expect(PermissionMapping.systemAudio(processTapSupported: false, openedBefore: false, deniedThisRun: true) == .granted, "old macOS has no system-audio prompt")
            await expect(PermissionMapping.systemAudio(processTapSupported: true, openedBefore: true, deniedThisRun: false) == .granted, "a tap that opened before counts as granted")
            await expect(PermissionMapping.systemAudio(processTapSupported: true, openedBefore: true, deniedThisRun: true) == .granted, "an earlier success wins over a failure this run")
            await expect(PermissionMapping.systemAudio(processTapSupported: true, openedBefore: false, deniedThisRun: true) == .denied, "a failure this run is denied")
            await expect(PermissionMapping.systemAudio(processTapSupported: true, openedBefore: false, deniedThisRun: false) == .unknown, "never asked -> unknown")

            await expect(PermissionMapping.screenRecording(alreadyGranted: true, preflightGranted: false, deniedThisRun: true) == .granted, "a live grant is not downgraded by a stale preflight")
            await expect(PermissionMapping.screenRecording(alreadyGranted: false, preflightGranted: true, deniedThisRun: false) == .granted, "preflight granted -> granted")
            await expect(PermissionMapping.screenRecording(alreadyGranted: false, preflightGranted: false, deniedThisRun: true) == .denied, "our own refusal -> denied")
            await expect(PermissionMapping.screenRecording(alreadyGranted: false, preflightGranted: false, deniedThisRun: false) == .unknown, "nothing known -> unknown")

            let ok = PermissionMapping.speechRequestOutcome(.authorized)
            await expect(ok.status == .granted && ok.issue == nil, "speech request granted -> no issue")
            let restricted = PermissionMapping.speechRequestOutcome(.restricted)
            await expect(restricted.status == .denied && restricted.issue?.contains("device policy") == true, "restricted speech names the device policy")
            let denied = PermissionMapping.speechRequestOutcome(.denied)
            await expect(denied.status == .denied && denied.issue?.contains("Turn on Whisper Pilot") == true, "denied speech says where to turn it on")
            await expect(PermissionMapping.speechRequestOutcome(.notDetermined).status == .denied, "an unanswered request is treated as not allowed")
        }
    }
}
