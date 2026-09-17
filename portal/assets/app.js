import { fetchReleases, formatBytes, formatDate } from "./releases.js";

const page = document.body.dataset.page;

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text) node.textContent = text;
  return node;
}

async function loadLatestRelease() {
  const download = document.querySelector("[data-latest-download]");
  const meta = document.querySelector("[data-latest-meta]");

  try {
    const [release] = await fetchReleases({ latest: true });
    if (!release?.downloadUrl) throw new Error("Latest release has no DMG");

    download.href = release.downloadUrl;
    download.querySelector("span").textContent = `Download v${release.version}`;
    meta.textContent = `${formatBytes(release.size)} · Released ${formatDate(release.publishedAt)} · macOS 14+`;
  } catch {
    meta.textContent = "Latest release · macOS 14+";
  }
}

function createReleaseRow(release, isLatest) {
  const row = element("article", "release-row");
  const identity = element("div", "release-identity");
  const titleLine = element("div", "release-title-line");
  const title = element("h3", "", `Whisper Pilot ${release.version}`);

  titleLine.append(title);
  if (isLatest) titleLine.append(element("span", "latest-badge", "Latest"));
  if (release.prerelease) titleLine.append(element("span", "prerelease-badge", "Pre-release"));

  identity.append(titleLine, element("p", "", `Released ${formatDate(release.publishedAt)}`));

  const actions = element("div", "release-actions");
  const notes = element("a", "notes-link", "Release notes");
  notes.href = release.notesUrl;
  notes.target = "_blank";
  notes.rel = "noreferrer";
  actions.append(notes);

  if (release.downloadUrl) {
    const download = element("a", "download-link", "Download DMG");
    download.href = release.downloadUrl;
    if (release.size) download.setAttribute("aria-label", `Download version ${release.version}, ${formatBytes(release.size)}`);
    actions.append(download);
  } else {
    actions.append(element("span", "unavailable", "DMG unavailable"));
  }

  row.append(identity, actions);
  return row;
}

async function loadVersions() {
  const list = document.querySelector("[data-release-list]");
  const count = document.querySelector("[data-release-count]");
  const error = document.querySelector("[data-release-error]");

  try {
    const releases = await fetchReleases();
    list.replaceChildren(...releases.map((release, index) => createReleaseRow(release, index === 0)));
    list.setAttribute("aria-busy", "false");
    count.textContent = `${releases.length} ${releases.length === 1 ? "release" : "releases"}`;
  } catch {
    list.hidden = true;
    error.hidden = false;
    count.textContent = "Unavailable";
  }
}

if (page === "home") loadLatestRelease();
if (page === "versions") loadVersions();
