# Changelog

All notable changes to this fork are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This is a fork of [johnohhh1/chatgpt_desktop_ubuntu](https://github.com/johnohhh1/chatgpt_desktop_ubuntu).
Everything below is what this fork adds on top of the upstream project (forked at
upstream commit `d57ffe7`).

## [Unreleased]

### Added

- **`download-latest-msixbundle.py`** — fetches the newest official ChatGPT
  Desktop `.msixbundle` straight from Microsoft's Store delivery backend
  (`displaycatalog` catalog + the FE3 Windows Update service), the same path the
  store.rg-adguard.net generator uses server-side — no browser or Cloudflare
  challenge involved. Saves the bundle next to the build script, ready to feed
  it. Flags: `--print-url`, `--out-dir`, `--force`, `--insecure`.
- **Automatic bundle discovery** — the build now auto-selects the newest
  MSIX/AppX bundle in the project folder (by parsed version) when `--exe` is not
  given, instead of requiring a hardcoded filename.
- **Electron version alignment** (`align_electron` step) — reads the exact
  Electron version the upstream app was built against from the payload's
  `app/version`, and installs that matching version into `./node_modules` on
  mismatch, so a stale local `^X.0.0` float can't silently ship a several-major
  behind Electron under the official app resources.
- **Window state persistence** (`include/window-state.mjs`) — remembers the
  window's position, size, and maximized state across restarts, and centers on
  the primary display on first run. Injected into the bundled main process at
  build time.
- **`package.json` / `package-lock.json`** — pin the local Electron build
  tooling (`@electron/asar`, `electron`) so a plain `npm install` provisions
  `./node_modules`.
- **Resilient patch targeting** — the main-process file is now located by
  content instead of by its hash-based name (e.g. `main-B4qvGjkf.js`), which
  changes every upstream release. The build fails loudly with a clear message
  if the expected patch anchor is missing or ambiguous.
- **Expanded README** documenting the download helper, Electron alignment,
  sandbox setup, and the new Linux patches.

### Changed

- **Chromium sandbox is now enabled** — the launcher no longer passes
  `--no-sandbox`. The package's `postinst` sets the bundled `chrome-sandbox`
  helper to `root:root` + setuid (`chmod 4755`) at install time, matching what
  the official VS Code / Slack / Discord Electron packages do.
- **Desktop `StartupWMClass`** is now set to the app's real `productName`
  (currently `ChatGPT Classic`, read from the app's own `package.json` at build
  time) instead of a hardcoded `electron`, so GNOME binds the running window to
  this launcher — showing the ChatGPT icon and name rather than a generic,
  icon-less entry.
- **`npm`** is now part of the dependency check (needed for Electron alignment).
- `.gitignore` now ignores `*.Msixbundle`.

### Fixed

- **Invisible system tray icon** — the bundled Electron binary is renamed to
  `chatgpt` so `app.isPackaged` reports `true`. While named `electron`, Electron
  treats the app as unpackaged and resolves the tray icon from a path inside the
  asar that does not exist, leaving an invisible (but still clickable) tray icon.
- **Generic gear icon in GNOME** — fixed via the real `StartupWMClass` above.
- **Silent Electron major-version drift** — fixed via the Electron alignment
  step above.

### Removed

- **`build-chatgpt-deb.sh`** — the legacy (non-native) build script.
- **Committed `.Msixbundle` payload** — bundles are now downloaded on demand and
  git-ignored instead of being checked into the repo.
- **Committed `.deb` artifact** under `dist/` — build output is no longer
  tracked.

[Unreleased]: https://github.com/muzsij/chatgpt_desktop_ubuntu/commits/main
