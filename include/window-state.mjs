// Persist and restore the main window's position, size and maximized state.
//
// This file is injected into the repackaged ChatGPT app by
// build-chatgpt-native-deb.sh. It is copied next to the bundled main-process
// code (.vite/build/) and imported from the window-manager module, which calls
// installWindowState(mainWindow) right after the BrowserWindow is created.
//
// It is deliberately self-contained and depends only on the public "electron"
// API (never on the app's minified internals), so it keeps working across
// upstream releases as long as the injection anchor still matches.

import { app, screen } from "electron";
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { join } from "node:path";

const STATE_FILE = "window-state.json";
const MIN_W = 360;
const MIN_H = 340;
const SAVE_DEBOUNCE_MS = 500;

function statePath() {
  return join(app.getPath("userData"), STATE_FILE);
}

function readState() {
  try {
    const raw = readFileSync(statePath(), "utf-8");
    const s = JSON.parse(raw);
    if (
      s &&
      Number.isFinite(s.x) &&
      Number.isFinite(s.y) &&
      Number.isFinite(s.width) &&
      Number.isFinite(s.height) &&
      s.width >= MIN_W &&
      s.height >= MIN_H
    ) {
      return {
        x: Math.round(s.x),
        y: Math.round(s.y),
        width: Math.round(s.width),
        height: Math.round(s.height),
        maximized: !!s.maximized,
      };
    }
  } catch {
    // no state yet or unreadable/corrupt -> fall back to centering
  }
  return null;
}

function writeState(state) {
  try {
    const tmp = statePath() + ".tmp";
    writeFileSync(tmp, JSON.stringify(state), "utf-8");
    renameSync(tmp, statePath());
  } catch {
    // never let a persistence failure crash the app
  }
}

// A saved rectangle is usable only if a meaningful chunk of it still lands on a
// currently connected display's work area (e.g. the monitor it was on may have
// been unplugged, or the layout may have changed).
function isVisibleOnSomeDisplay(bounds) {
  for (const d of screen.getAllDisplays()) {
    const wa = d.workArea;
    const iw =
      Math.min(bounds.x + bounds.width, wa.x + wa.width) - Math.max(bounds.x, wa.x);
    const ih =
      Math.min(bounds.y + bounds.height, wa.y + wa.height) - Math.max(bounds.y, wa.y);
    // require at least a 200x100 visible patch so the title bar stays grabbable
    if (iw >= Math.min(200, bounds.width) && ih >= Math.min(100, bounds.height)) {
      return true;
    }
  }
  return false;
}

function primaryCenteredBounds(width, height) {
  const wa = screen.getPrimaryDisplay().workArea;
  return {
    x: Math.round(wa.x + (wa.width - width) / 2),
    y: Math.round(wa.y + (wa.height - height) / 2),
    width,
    height,
  };
}

export function installWindowState(win) {
  if (!win || win.isDestroyed()) return;

  const saved = readState();
  // The geometry we ask the OS for. `null` means "leave the OS/app default".
  const target =
    saved && isVisibleOnSomeDisplay(saved)
      ? { x: saved.x, y: saved.y, width: saved.width, height: saved.height }
      : null;
  const wantMaximized = !!(saved && saved.maximized);

  let applied = null;
  // On X11/GNOME the window manager shifts the frame by the title-bar height on
  // map, so getBounds() afterwards differs from what we set. We measure that
  // constant offset once the window has settled and subtract it on save, or the
  // saved position would creep on every launch.
  let offset = { x: 0, y: 0 };
  // Tracking only starts once the restore has settled, so the app's own resize
  // back to the default content size (see below) is never persisted.
  let ready = false;

  const applyTarget = () => {
    try {
      if (target) {
        applied = target;
      } else {
        const b = win.getBounds();
        applied = primaryCenteredBounds(b.width, b.height);
      }
      win.setBounds(applied);
    } catch {
      applied = null; // leave OS default placement if anything went wrong
    }
  };

  // 1) Apply once up front so the initial position/size hints are correct.
  applyTarget();

  // 2) Re-apply after the window is shown. The app builds the window with
  //    useContentSize + a default width/height, and that content-size hint
  //    resets the window back to the default size at map time, undoing our
  //    pre-show setBounds. Re-applying after "show" makes it stick.
  win.once("show", () => {
    setTimeout(() => {
      applyTarget();
      if (wantMaximized) win.maximize();
      // 3) Once it has settled, measure the frame offset, then start tracking.
      setTimeout(() => {
        if (!win.isDestroyed() && applied && !win.isMaximized()) {
          const b = win.getBounds();
          offset = { x: b.x - applied.x, y: b.y - applied.y };
        }
        ready = true;
      }, 300);
    }, 0);
  });

  // --- track ---
  const snapshot = () => {
    if (win.isDestroyed()) return null;
    // getNormalBounds() is the un-maximized/un-minimized geometry, which is what
    // we want to restore to; the maximized flag is stored separately.
    const b = win.getNormalBounds();
    return {
      x: Math.round(b.x - offset.x),
      y: Math.round(b.y - offset.y),
      width: b.width,
      height: b.height,
      maximized: win.isMaximized(),
    };
  };

  const save = () => {
    // Ignore events fired while restoring; persisting then would overwrite the
    // saved geometry with the app's transient default size.
    if (!ready) return;
    const s = snapshot();
    if (s) writeState(s);
  };

  let timer = null;
  const saveDebounced = () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(save, SAVE_DEBOUNCE_MS);
  };

  win.on("resize", saveDebounced);
  win.on("move", saveDebounced);
  win.on("maximize", save);
  win.on("unmaximize", save);
  // Persist synchronously on close so the final position is never lost, even if
  // the debounce timer hasn't fired yet.
  win.on("close", () => {
    if (timer) clearTimeout(timer);
    save();
  });
}
