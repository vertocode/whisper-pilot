# Release process

How to cut a new version of Whisper Pilot, ship it as a DMG, and make it installable via Homebrew. **Once the one-time setup is done, releasing is a single button-click.**

## TL;DR (recommended — manual CI trigger)

1. Go to [**Actions → Release**](https://github.com/vertocode/whisper-pilot/actions/workflows/release.yml) on GitHub.
2. Click **Run workflow** (top right).
3. Type a version (e.g. `0.2.0`), click **Run workflow** again.

The workflow checks out the current `main`, builds the DMG, creates a GitHub Release `v0.2.0` with the DMG attached, and — if you've configured the tap token (see [one-time setup](#one-time-setup)) — bumps the [Homebrew tap](https://github.com/vertocode/homebrew-whisper-pilot) cask file so users running `brew upgrade --cask whisper-pilot` get the new build automatically.

## Other triggers

| How | What happens |
| --- | --- |
| `git tag v0.2.0 && git push origin v0.2.0` | Same workflow runs, version is parsed from the tag |
| `./bin/release 0.2.0` (local) | Same DMG build, but no GitHub Release or tap update — you'd have to upload manually |

## One-time setup

To make `brew install` deliver a working app, the workflow needs to push to the [tap repo](https://github.com/vertocode/homebrew-whisper-pilot). The default `GITHUB_TOKEN` of a workflow can only push to its own repository, so we need a personal access token (PAT) for cross-repo writes.

### 1. Make the tap repo public

```sh
gh repo edit vertocode/homebrew-whisper-pilot --visibility public --accept-visibility-change-consequences
```

Homebrew can't clone private repos without per-user authentication, so this is required for the "anyone can `brew install`" goal.

### 2. Create a fine-grained PAT for the tap

1. Visit [GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens](https://github.com/settings/tokens?type=beta).
2. **Generate new token** → give it a name like `whisper-pilot-tap-write`.
3. **Resource owner:** your user. **Expiration:** 1 year (or as long as you're comfortable).
4. **Repository access:** Only select repositories → pick `vertocode/homebrew-whisper-pilot`.
5. **Repository permissions:** `Contents: Read and Write`. Nothing else.
6. Click **Generate token**, copy the value.

### 3. Add the PAT as a secret on the whisper-pilot repo

1. Visit [vertocode/whisper-pilot → Settings → Secrets and variables → Actions](https://github.com/vertocode/whisper-pilot/settings/secrets/actions).
2. **New repository secret** → name `TAP_REPO_TOKEN`, value = the PAT from step 2.

That's it. From this point onward, every release workflow run also bumps the tap cask.

### Optional: enable signing & notarization (Tier 3)

Set additionally:

| Secret | What it is |
| --- | --- |
| `WP_DEVELOPER_ID_CERT_BASE64` | Your Developer ID Application certificate, exported as `.p12`, then `base64`-encoded |
| `WP_DEVELOPER_ID_CERT_PASSWORD` | The password you set when exporting the `.p12` |
| `WP_DEVELOPER_ID` | The certificate Common Name, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `WP_APPLE_ID` | Your Apple ID email |
| `WP_APPLE_APP_PASSWORD` | An app-specific password from [appleid.apple.com](https://appleid.apple.com) |
| `WP_TEAM_ID` | Your 10-character Apple Developer Team ID |

Without these, builds ship unsigned and users must right-click → Open the first time (see [Tier 1 below](#tier-1-unsigned-free-anyone-can-download)).

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

### Route A: Personal tap (what we use)

A "tap" is a GitHub repo named `homebrew-<something>` that Homebrew can install from. Ours is [vertocode/homebrew-whisper-pilot](https://github.com/vertocode/homebrew-whisper-pilot), already populated.

After [one-time setup](#one-time-setup), every release run by the workflow **automatically pushes the new `version` and `sha256` to the tap**. No manual file editing.

Then anyone can install:

```sh
brew install --cask vertocode/whisper-pilot/whisper-pilot
```

The `vertocode/whisper-pilot/` prefix is Homebrew's way of saying *use my tap, not homebrew-cask*. `brew upgrade --cask whisper-pilot` works as expected — the tap commit pushed by CI is what users pull.

The `Casks/whisper-pilot.rb` checked into *this* repo is a reference copy / template — the workflow always pushes its update to the tap repo, not back here, so contributors reading the source see the cask schema but don't need to keep its `version` field in sync manually.

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
- [ ] Bump `CFBundleShortVersionString` in `Project.yml` if needed (the CI workflow passes `MARKETING_VERSION=<input>` to xcodebuild, so this is informational rather than required).
- [ ] Update `docs/ROADMAP.md` (move shipped items out, add new ones).
- [ ] Trigger the release: either **Actions → Release → Run workflow** with the version typed in, or `git tag vX.Y.Z && git push origin vX.Y.Z`.
- [ ] Wait for the workflow to finish. It builds the DMG, creates the GitHub Release, and bumps the tap cask.
- [ ] On a clean Mac (or after `brew uninstall --cask whisper-pilot`), verify:
      `brew install --cask vertocode/whisper-pilot/whisper-pilot` → the new version installs.
