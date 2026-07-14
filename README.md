# ChatGPT Native Linux Repack

This folder contains the working local build path that repackages the official
Windows ChatGPT MSIX into a native Linux Electron `.deb`.

This is the path that worked on this machine. An earlier approach wrapped the
Windows app under Wine; that has been dropped in favor of this native build.

## Files

- `build-chatgpt-native-deb.sh`
  - main build script
- `package.json`
  - pins the local Electron build tooling (`npm install` reads it)
- `download-latest-msixbundle.py`
  - fetches the latest official ChatGPT `.msixbundle` from Microsoft
- `OpenAI.ChatGPT-Desktop_<version>.Msixbundle`
  - input payload (the build auto-selects the newest one in this folder)
- `dist/chatgpt-desktop-native_<version>_amd64.deb`
  - output package

## Getting The Latest Bundle

`download-latest-msixbundle.py` pulls the newest official ChatGPT Desktop
package straight from Microsoft's Store delivery backend (the `displaycatalog`
catalog plus the FE3 Windows Update service) and drops it in this folder — the
same backend the store.rg-adguard.net generator uses, but with no browser or
Cloudflare challenge in the way.

```bash
./download-latest-msixbundle.py --insecure
```

Useful flags:

- `--print-url` resolve and print the direct download URL only
- `--out-dir DIR` save somewhere other than this folder
- `--force` re-download even if the file already exists
- `--insecure` skip TLS verification (only needed if the local CA store
  cannot verify Microsoft's delivery endpoints)

The bundle is saved as `OpenAI.ChatGPT-Desktop_<version>.Msixbundle`, ready to
feed to the build script. Only Python 3 and network access are required.

## What The Native Script Does

1. extracts the `x64` MSIX from the bundle
2. extracts the official `app.asar`
3. patches a few Windows/macOS assumptions so the app can boot on Linux
4. aligns the local Electron to the exact version the payload was built against
   (read from `app/version`), installing it if the local one differs
5. stages Linux Electron around the official app resources
6. packages everything as `chatgpt-desktop-native`

## Current Linux Patches

- routes the platform chooser through the macOS-style implementation on Linux
- disables macOS-only `setVibrancy(...)` calls on Linux
- avoids the macOS `ioreg` device ID path on Linux
- carries over the official `assets/` directory expected by the app
- renames the bundled Electron binary (to `chatgpt`) so `app.isPackaged` is
  true: while it is named `electron`, Electron reports the app as unpackaged
  and resolves the tray icon from a path inside the asar that does not exist,
  leaving an invisible (but still clickable) system tray icon
- declares `chatgpt:` and `chatgpt-alt:` URL handlers in the desktop file
- sets the desktop entry `StartupWMClass` to the app's real `productName`
  (currently `ChatGPT Classic`, read from the app's own `package.json` at build
  time) so GNOME binds the running window to this launcher — showing the ChatGPT
  icon and name instead of a generic, icon-less entry. Electron derives the X11
  `WM_CLASS` from `productName`, and once the binary rename above makes the app
  packaged, that becomes `ChatGPT Classic` rather than `electron`, so the class
  is discovered from the payload instead of hardcoded

## Electron Version

The upstream Windows payload ships the exact Electron version the app was built
against in `app/version`. The build reads it and, if the local Electron differs,
pulls the matching version into `./node_modules` before staging (so a stale
local `^X.0.0` float can't silently ship a several-major-behind Electron under
the official app resources). `package.json` tracks the current upstream baseline
as a convenience for a fresh `npm install`, but the build is the source of truth.

## Sandbox

The launcher runs Electron with the Chromium sandbox **enabled** (no
`--no-sandbox`). The package's `postinst` sets the bundled `chrome-sandbox`
helper to `root:root` + setuid (`chmod 4755`) at install time, the same setup
the official VS Code / Slack / Discord Electron packages use. Because the setuid
bit is applied on install, launching the staged app directly from a build tree
(before `dpkg` install) will fail the sandbox check — that is expected.

## Dependencies

The build expects local Electron tooling in this folder. A `package.json`
pins the versions, so a plain install drops them into `./node_modules`:

```bash
npm install
```

System tools used by the script:

```bash
sudo apt-get install -y dpkg-dev nodejs python3 file
```

## Build

By default the script picks up the newest `.Msixbundle` / `.msix` in this
folder automatically (highest version wins), so after downloading a bundle you
can just run:

```bash
./build-chatgpt-native-deb.sh
```

To build a specific payload instead, pass it explicitly:

```bash
./build-chatgpt-native-deb.sh --exe ./OpenAI.ChatGPT-Desktop_<version>.Msixbundle
```

The patch step locates the bundled main-process file by its contents, so it
keeps working across releases even though its hashed filename
(`main-<hash>.js`) changes every version.

## Install

```bash
sudo apt-get install ./dist/chatgpt-desktop-native_<version>_amd64.deb
```

If you rebuild without changing the version string, force the package refresh:

```bash
sudo apt-get install --reinstall ./dist/chatgpt-desktop-native_<version>_amd64.deb
```

## Register The Login Callback

The package installs a helper that registers the current desktop user as the
handler for the auth callback schemes:

```bash
chatgpt-desktop-native-register
```

You can verify registration with:

```bash
xdg-mime query default x-scheme-handler/chatgpt
xdg-mime query default x-scheme-handler/chatgpt-alt
```

Expected result:

```text
chatgpt-desktop-native.desktop
```

## Launch

```bash
chatgpt-desktop-native
```

## Reproducing On Another Machine

1. copy this folder to the target machine
2. place a real ChatGPT `.msix`, `.msixbundle`, `.appx`, or `.appxbundle` here
3. run the local `npm install`
4. run `./build-chatgpt-native-deb.sh --exe <payload>`
5. install the generated `.deb`
6. run `chatgpt-desktop-native-register`
7. launch `chatgpt-desktop-native`
8. if GNOME still shows the old generic icon, fully close the app and relaunch
   it once; if the shell is stubborn, log out and back in once

## Notes

- the app may still print Electron/NVIDIA/VA-API noise in the terminal
- the successful signal is functional login plus working chat, not a silent
  terminal
- if the upstream Windows app changes significantly, the patch targets in
  `build-chatgpt-native-deb.sh` may need to be updated
