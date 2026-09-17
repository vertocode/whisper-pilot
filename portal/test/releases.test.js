import test from "node:test";
import assert from "node:assert/strict";

import { findDmg, formatBytes, normalizeRelease } from "../assets/releases.js";

const release = {
  tag_name: "v0.1.25",
  name: "Whisper Pilot 0.1.25",
  published_at: "2026-09-17T00:57:57Z",
  prerelease: false,
  html_url: "https://github.com/vertocode/whisper-pilot/releases/tag/v0.1.25",
  assets: [
    { name: "checksums.txt", browser_download_url: "https://example.com/checksums", size: 120 },
    { name: "WhisperPilot-0.1.25.DMG", browser_download_url: "https://example.com/app.dmg", size: 7_191_969 },
  ],
};

test("findDmg finds DMG assets case-insensitively", () => {
  assert.equal(findDmg(release)?.name, "WhisperPilot-0.1.25.DMG");
});

test("normalizeRelease exposes portal fields", () => {
  assert.deepEqual(normalizeRelease(release), {
    version: "0.1.25",
    name: "Whisper Pilot 0.1.25",
    publishedAt: "2026-09-17T00:57:57Z",
    prerelease: false,
    notesUrl: "https://github.com/vertocode/whisper-pilot/releases/tag/v0.1.25",
    downloadUrl: "https://example.com/app.dmg",
    size: 7_191_969,
  });
});

test("normalizeRelease tolerates releases without DMG assets", () => {
  const normalized = normalizeRelease({ ...release, assets: [] });
  assert.equal(normalized.downloadUrl, undefined);
  assert.equal(normalized.size, undefined);
});

test("formatBytes uses decimal megabytes", () => {
  assert.equal(formatBytes(7_191_969), "7.2 MB");
  assert.equal(formatBytes(undefined), "");
});
