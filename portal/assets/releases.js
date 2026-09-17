export const RELEASES_API = "https://api.github.com/repos/vertocode/whisper-pilot/releases";

export function findDmg(release) {
  return release.assets?.find((asset) => asset.name.toLowerCase().endsWith(".dmg"));
}

export function normalizeRelease(release) {
  const dmg = findDmg(release);

  return {
    version: release.tag_name.replace(/^v/, ""),
    name: release.name || release.tag_name,
    publishedAt: release.published_at,
    prerelease: release.prerelease,
    notesUrl: release.html_url,
    downloadUrl: dmg?.browser_download_url,
    size: dmg?.size,
  };
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "";
  return `${(bytes / 1_000_000).toFixed(1)} MB`;
}

export function formatDate(value) {
  return new Intl.DateTimeFormat("en", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(new Date(value));
}

export async function fetchReleases({ latest = false } = {}) {
  const endpoint = latest ? `${RELEASES_API}/latest` : `${RELEASES_API}?per_page=100`;
  const response = await fetch(endpoint, {
    headers: { Accept: "application/vnd.github+json" },
  });

  if (!response.ok) throw new Error(`GitHub releases request failed: ${response.status}`);

  const payload = await response.json();
  const releases = Array.isArray(payload) ? payload : [payload];
  return releases.filter((release) => !release.draft).map(normalizeRelease);
}
