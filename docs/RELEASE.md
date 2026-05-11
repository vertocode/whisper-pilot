# Release process

How to cut a new version of Whisper Pilot, ship it as a DMG, and make it installable via Homebrew.

## TL;DR

```sh
# bump the version in Project.yml (CFBundleShortVersionString), commit, then:
git tag v0.2.0
git push origin v0.2.0
```

The `.github/workflows/release.yml` workflow takes over from there: it builds, packages, and creates a GitHub Release with the DMG attached.

If you don't have CI set up yet, run the same script locally:

```sh
./bin/release 0.2.0
```

That produces `build/WhisperPilot-0.2.0.dmg` and a sibling `.sha256`.

---

## What the release script does

`bin/release` chains five steps:

1. **Regenerate the Xcode project** — runs `xcodegen` so the `.xcodeproj` matches `Project.yml`.
2. **Archive** — `xcodebuild archive` in Release configuration produces a `.xcarchive`.
3. **Export** — pulls the `.app` out of the archive.
4. **(Optional) Sign & notarize** — only if the right env vars / secrets are present (see below).
5. **Package** — `create-dmg` wraps the `.app` into a nicely-laid-out installer DMG.

Output:

```
build/
  WhisperPilot-0.2.0.dmg
  WhisperPilot-0.2.0.dmg.sha256
```

## Three distribution tiers

You can ship at any of these tiers. Each has trade-offs.

### Tier 1: Unsigned, free, anyone can download

This is where you are today. No Apple Developer Program subscription required.

- Run `./bin/release` with **no** signing env vars set.
- Upload the DMG to GitHub Releases.
- Users download, double-click, drag to Applications.
- **First launch:** macOS Gatekeeper shows *"can't be opened because Apple cannot check it for malicious software"*. The user has to either:
  - Right-click the app → **Open** → **Open** in the dialog. macOS remembers and stops asking.
  - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/WhisperPilot.app`

**Good for:** alpha / beta / open source where users tolerate one extra click.
**Bad for:** anyone non-technical. Most users will see the warning and bounce.

### Tier 2: Signed with a Developer ID, no notarization

Requires the $99/year [Apple Developer Program](https://developer.apple.com/programs/) membership.

- Create a Developer ID Application certificate in Apple Developer → Certificates.
- Install it in your Keychain.
- Export `WP_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"` before running `./bin/release`.

The build signs the `.app` and `.dmg`. Gatekeeper still warns the *first* time because Apple hasn't actively scanned the binary, but the warning is softer and users can dismiss it more easily.

**Good for:** stopgap before you set up notarization.
**Bad for:** most modern macOS — Apple really wants notarization too.

### Tier 3: Signed + notarized (production)

Same Developer ID as Tier 2, plus an app-specific password for `notarytool`.

- In `appleid.apple.com` → Sign-In and Security → App-Specific Passwords → generate one.
- Set all four env vars before running `./bin/release`:
  ```sh
  export WP_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
  export WP_APPLE_ID="your.email@example.com"
  export WP_APPLE_APP_PASSWORD="abcd-efgh-ijkl-mnop"
  export WP_TEAM_ID="ABCDEFGHIJ"
  ```

The build signs, uploads to Apple for notarization, waits ~1–10 min for the result, then staples the ticket onto both the `.app` and the `.dmg`. Users see no warnings whatsoever.

**Good for:** general public distribution. Required if you want Homebrew Cask without the "this is unsigned" warning every time.

## GitHub Releases hosting

GitHub Releases is free for public repos and is what `release.yml` uses. No setup beyond pushing the tag.

To do it manually:

```sh
gh release create v0.2.0 build/WhisperPilot-0.2.0.dmg \
    --title "Whisper Pilot 0.2.0" \
    --notes "Changelog goes here"
```

## Homebrew Cask

Casks are how non-formula macOS apps get distributed via `brew install`.

There are two routes:

### Route A: Personal tap (faster, what we use)

A "tap" is a GitHub repo named `homebrew-<something>` that Homebrew can install from.

1. Create a new repo: `vertocode/homebrew-whisper-pilot`.
2. Add a single file: `Casks/whisper-pilot.rb`. The canonical version of that file lives in this repo at `Casks/whisper-pilot.rb` — copy it across.
3. After each release, update `version` and `sha256` in the cask file (the values are printed at the end of `./bin/release`).

Then anyone can install:

```sh
brew install --cask vertocode/whisper-pilot/whisper-pilot
```

The `vertocode/whisper-pilot/` prefix is Homebrew's way of saying *use my tap, not homebrew-cask*. `brew upgrade` works as expected — push a new cask, users get the new version.

### Route B: Submit to homebrew-cask (more reach, more friction)

Open a PR to [homebrew/homebrew-cask](https://github.com/homebrew/homebrew-cask) with your cask file. Homebrew maintainers will review it. Their bar:

- App **must** be signed with a Developer ID (Tier 2 or 3).
- App **must** be notarized for new submissions (Tier 3).
- A real homepage, a real version, a real download URL.
- No "alpha"-quality stuff that crashes on launch.

If accepted, anyone can run `brew install --cask whisper-pilot` with no tap prefix. But you need Tier 3 signing first.

## Auto-updates (not yet wired)

Once you ship v0.1.0, every release after that needs to reach existing users somehow. Three options:

1. **Re-download every time** — manual, what we have now.
2. **Homebrew** — `brew upgrade --cask whisper-pilot` does the right thing if the cask is up to date.
3. **[Sparkle](https://sparkle-project.org/)** — the standard macOS auto-updater. The app checks an `appcast.xml` on launch and prompts to update. Most professional Mac apps use this.

If you want Sparkle, add it later — it's a separate piece of work and isn't strictly required for distribution.

## Checklist for each release

- [ ] All wanted PRs merged to `main`.
- [ ] Bump `CFBundleShortVersionString` in `Project.yml`.
- [ ] Run `./bin/regenerate` and verify the `.xcodeproj` builds.
- [ ] Update `docs/ROADMAP.md` (move shipped items out, add new ones).
- [ ] Tag: `git tag vX.Y.Z && git push origin vX.Y.Z` — CI handles the rest.
- [ ] Copy `version` and `sha256` from the CI output into `Casks/whisper-pilot.rb`.
- [ ] Push the updated cask to the `homebrew-whisper-pilot` tap repo.
- [ ] Verify the install end-to-end on a fresh user:
      `brew install --cask vertocode/whisper-pilot/whisper-pilot`.
