# Homebrew Cask formula for Whisper Pilot.
#
# This file lives both in this repo (as the canonical source) and is mirrored to a
# personal Homebrew tap at github.com/vertocode/homebrew-whisper-pilot so users can run:
#
#     brew install --cask vertocode/whisper-pilot/whisper-pilot
#
# After every release, run `./bin/release`, copy the resulting `version` and `sha256` into
# this file, push to the tap repo, and the cask installs the new build for everyone who
# runs `brew upgrade`.
#
# Note: until the DMG is signed with a Developer ID and notarized by Apple, Gatekeeper
# will warn on first launch. Users can dismiss the warning with:
#     xattr -dr com.apple.quarantine /Applications/WhisperPilot.app
# or right-click the app and pick "Open" the first time.

cask "whisper-pilot" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_BIN_RELEASE_OUTPUT"

  url "https://github.com/vertocode/whisper-pilot/releases/download/v#{version}/WhisperPilot-#{version}.dmg",
      verified: "github.com/vertocode/whisper-pilot/"
  name "Whisper Pilot"
  desc "Ambient, local-first AI co-pilot for live conversations"
  homepage "https://github.com/vertocode/whisper-pilot"

  depends_on macos: ">= :sonoma"

  app "WhisperPilot.app"

  # Clean up Application Support and Keychain entries on uninstall. We intentionally
  # leave session transcripts in `~/Library/Application Support/com.whisperpilot.app/sessions`
  # alone — those are user data, not application state.
  uninstall quit: "com.whisperpilot.app"

  zap trash: [
    "~/Library/Application Support/com.whisperpilot.app",
    "~/Library/Preferences/com.whisperpilot.app.plist",
    "~/Library/Caches/com.whisperpilot.app",
  ]
end
