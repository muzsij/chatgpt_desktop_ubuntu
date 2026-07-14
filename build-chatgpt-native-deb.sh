#!/usr/bin/env bash
set -euo pipefail

readonly PACKAGE_NAME="chatgpt-desktop-native"
readonly APP_NAME="ChatGPT"
# The Electron binary must NOT be named "electron": app.isPackaged is false
# whenever basename(execPath) == "electron", which sends the app down its
# dev-mode resource-path branch and breaks the tray icon (loads it from a
# path inside the asar that does not exist -> empty/invisible tray icon).
readonly ELECTRON_BIN_NAME="chatgpt"
readonly MAINTAINER="${MAINTAINER:-JohnO Local Build}"
readonly DESCRIPTION="ChatGPT desktop app repackaged from the official Windows MSIX into a native Linux Electron package"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_PAYLOAD=""
OUT_DIR="${PROJECT_ROOT}/dist"
BUILD_DIR="${PROJECT_ROOT}/build-native"
ARCH="amd64"
VERSION=""
CLEAN="yes"

section() {
  printf "\n\033[1;36m== %s ==\033[0m\n" "$1"
}

die() {
  printf "\033[1;31merror:\033[0m %s\n" "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --exe PATH         Path to the ChatGPT MSIX/MSIXBundle payload
                     (default: newest bundle found in the project folder)
  --version VERSION  Override package version
  --out-dir DIR      Output directory for the built .deb
  --clean yes|no     Remove build directory after success (default: yes)
  -h, --help         Show this help
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --exe)
        INPUT_PAYLOAD="${2:-}"
        shift 2
        ;;
      --version)
        VERSION="${2:-}"
        shift 2
        ;;
      --out-dir)
        OUT_DIR="${2:-}"
        shift 2
        ;;
      --clean)
        CLEAN="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

check_deps() {
  section "Dependency Check"
  local missing=()
  for cmd in file dpkg-deb python3 node npm; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  [[ -x "${PROJECT_ROOT}/node_modules/.bin/asar" ]] || missing+=("node_modules/.bin/asar")
  [[ -x "${PROJECT_ROOT}/node_modules/electron/dist/electron" ]] || missing+=("node_modules/electron/dist/electron")

  if ((${#missing[@]} > 0)); then
    printf "missing tools: %s\n" "${missing[*]}"
    printf "expected local setup:\n"
    printf "  cd %s && npm install electron @electron/asar --no-save\n" "$PROJECT_ROOT"
    die "required build tools are missing"
  fi
}

discover_payload() {
  # Pick the newest MSIX/AppX payload in the project folder by parsed version.
  PROJECT_ROOT="$PROJECT_ROOT" python3 - <<'PY'
import glob, os, re

root = os.environ["PROJECT_ROOT"]
exts = ("*.Msixbundle", "*.msixbundle", "*.msix", "*.appx", "*.appxbundle")
candidates = []
for pat in exts:
    candidates.extend(glob.glob(os.path.join(root, pat)))
candidates = sorted(set(candidates))

def ver_key(path):
    m = re.search(r'_(\d+(?:\.\d+)*)\.(?:msix|appx)', os.path.basename(path), re.I)
    if m:
        return tuple(int(x) for x in m.group(1).split("."))
    return (0,)

if candidates:
    print(max(candidates, key=lambda p: (ver_key(p), os.path.getmtime(p))))
PY
}

validate_input() {
  section "Input Validation"

  if [[ -z "$INPUT_PAYLOAD" ]]; then
    INPUT_PAYLOAD="$(discover_payload)"
    [[ -n "$INPUT_PAYLOAD" ]] || die "no MSIX/AppX bundle found in ${PROJECT_ROOT} (pass one with --exe, or run ./download-latest-msixbundle.py)"
    printf "auto-selected newest bundle: %s\n" "$INPUT_PAYLOAD"
  fi

  [[ -f "$INPUT_PAYLOAD" ]] || die "input file not found: $INPUT_PAYLOAD"

  local detected
  detected="$(file -b "$INPUT_PAYLOAD")"
  printf "input: %s\n" "$INPUT_PAYLOAD"
  printf "type:  %s\n" "$detected"

  case "${INPUT_PAYLOAD,,}" in
    *.msix|*.msixbundle|*.appx|*.appxbundle) ;;
    *)
      die "native repack expects an MSIX/AppX payload, not a raw exe"
      ;;
  esac
}

prepare_dirs() {
  section "Workspace Setup"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR" "$OUT_DIR"
}

detect_version() {
  section "Version Detection"
  if [[ -n "$VERSION" ]]; then
    printf "using overridden version: %s\n" "$VERSION"
    return
  fi

  VERSION="$(INPUT_PAYLOAD="$INPUT_PAYLOAD" python3 - <<'PY'
import re, zipfile, os
src = os.environ["INPUT_PAYLOAD"]
with zipfile.ZipFile(src) as z:
    manifest_name = "AppxManifest.xml"
    if src.lower().endswith(("msixbundle", "appxbundle")):
        manifest_name = "AppxMetadata/AppxBundleManifest.xml"
    data = z.read(manifest_name).decode("utf-8", "replace")
m = re.search(r'<Identity\b[^>]*\bVersion="([0-9.]+)"', data)
print(m.group(1) if m else "")
PY
)"
  [[ -n "$VERSION" ]] || VERSION="1.0.0"
  printf "detected package version: %s\n" "$VERSION"
}

extract_payload() {
  section "Payload Extraction"
  INPUT_PAYLOAD="$INPUT_PAYLOAD" BUILD_DIR="$BUILD_DIR" python3 - <<'PY'
import os, pathlib, shutil, zipfile

src = pathlib.Path(os.environ["INPUT_PAYLOAD"])
root = pathlib.Path(os.environ["BUILD_DIR"])
payload_root = root / "payload"
payload_root.mkdir(parents=True, exist_ok=True)

def extract_zip(src_path: pathlib.Path, out_dir: pathlib.Path) -> None:
    with zipfile.ZipFile(src_path) as z:
        z.extractall(out_dir)

if src.suffix.lower() in {".msixbundle", ".appxbundle"}:
    with zipfile.ZipFile(src) as z:
        inner = None
        for name in z.namelist():
            lower = name.lower()
            if lower.endswith("_x64.msix") or lower.endswith("_x64.appx"):
                inner = name
                break
        if not inner:
            raise SystemExit("no x64 msix/appx found inside bundle")
        inner_path = root / "ChatGPT_x64.msix"
        inner_path.write_bytes(z.read(inner))
    extract_zip(inner_path, payload_root)
else:
    extract_zip(src, payload_root)
PY

  [[ -f "$BUILD_DIR/payload/app/resources/app.asar" ]] || die "missing app/resources/app.asar in extracted payload"
  [[ -d "$BUILD_DIR/payload/assets" ]] || die "missing assets directory in extracted payload"
}

align_electron() {
  section "Electron Version Alignment"

  # The upstream Windows payload ships the exact Electron version the app was
  # built against in app/version. The app's minified main process assumes that
  # Electron's behavior/ABI; staging a different major (the local ^X.0.0 float
  # can drift several majors behind upstream) risks subtle, silent breakage.
  # So read the required version and, on mismatch, pull the matching Electron
  # into node_modules before patch_app stages it.
  local required have
  required="$(tr -d '[:space:]' < "$BUILD_DIR/payload/app/version" 2>/dev/null || true)"
  required="${required#v}"
  if [[ -z "$required" ]]; then
    printf "could not read payload/app/version; using installed Electron as-is\n"
    return
  fi

  have="$(tr -d '[:space:]' < "${PROJECT_ROOT}/node_modules/electron/dist/version" 2>/dev/null || true)"
  have="${have#v}"

  printf "app was built against Electron: %s\n" "$required"
  printf "staged Electron:               %s\n" "${have:-unknown}"

  if [[ "$have" == "$required" ]]; then
    printf "already aligned\n"
    return
  fi

  printf "mismatch -> installing electron@%s\n" "$required"
  if npm --prefix "$PROJECT_ROOT" install "electron@${required}" \
       --no-save --no-package-lock --no-audit --no-fund >/dev/null 2>&1; then
    have="$(tr -d '[:space:]' < "${PROJECT_ROOT}/node_modules/electron/dist/version" 2>/dev/null || true)"
    have="${have#v}"
    printf "installed Electron: %s\n" "${have:-unknown}"
  else
    printf "\033[1;33mwarning:\033[0m npm could not install electron@%s (offline?)\n" "$required"
  fi

  if [[ "$have" != "$required" ]]; then
    if [[ "${have%%.*}" == "${required%%.*}" ]]; then
      printf "\033[1;33mwarning:\033[0m proceeding with Electron %s (same major as required %s)\n" \
        "$have" "$required"
    else
      die "Electron major mismatch: app needs $required but only $have is available; run 'npm install electron@$required' and rebuild"
    fi
  fi
}

patch_app() {
  section "Patch Official App"
  cp "$BUILD_DIR/payload/app/resources/app.asar" "$BUILD_DIR/app.asar"
  "${PROJECT_ROOT}/node_modules/.bin/asar" extract "$BUILD_DIR/app.asar" "$BUILD_DIR/app"

  node - "$BUILD_DIR/app/.vite/build" <<'NODE'
const fs = require('fs');
const path = require('path');
const buildDir = process.argv[2];

const replacements = [
  {
    from: 'const _ua = process.platform === "darwin", Mua = process.platform === "win32";',
    to: 'const _ua = process.platform === "darwin", Mua = process.platform === "win32", oqa_linux = process.platform === "linux";'
  },
  {
    from: 'if (_ua)\n    return u();',
    to: 'if (_ua || oqa_linux)\n    return u();'
  },
  {
    from: '  applyMainWindowStyle(u) {\n    u.setVibrancy("sidebar");\n  }',
    to: '  applyMainWindowStyle(u) {\n    process.platform === "darwin" && u.setVibrancy("sidebar");\n  }'
  },
  {
    from: '  applyCompanionWindowStyle(u) {\n    u.setVibrancy("hud");\n  }',
    to: '  applyCompanionWindowStyle(u) {\n    process.platform === "darwin" && u.setVibrancy("hud");\n  }'
  },
  {
    from: 'function jpa() {\n  try {',
    to: 'function jpa() {\n  if (process.platform === "linux")\n    return hu.hostname();\n  try {'
  }
];

// The bundled main process lives in a hash-named file (e.g. main-B4qvGjkf.js)
// that changes every release, so locate it by content instead of by name.
const anchor = replacements[0].from;
const candidates = fs
  .readdirSync(buildDir)
  .filter((n) => n.endsWith('.js'))
  .map((n) => path.join(buildDir, n));

const hits = candidates.filter((p) => fs.readFileSync(p, 'utf8').includes(anchor));

if (hits.length === 0) {
  console.error(`no JS file in ${buildDir} contains the expected patch target`);
  console.error(`  looked for: ${anchor.slice(0, 80)}`);
  console.error('  the upstream app likely changed; patch strings need updating');
  process.exit(1);
}
if (hits.length > 1) {
  console.error(`ambiguous patch target, matched multiple files: ${hits.join(', ')}`);
  process.exit(1);
}

const target = hits[0];
console.log(`patching ${path.basename(target)}`);
let src = fs.readFileSync(target, 'utf8');

for (const { from, to } of replacements) {
  if (!src.includes(from)) {
    console.error(`missing expected patch target: ${from.slice(0, 80)}`);
    process.exit(1);
  }
  src = src.replace(from, to);
}

fs.writeFileSync(target, src);
NODE

  # Inject the window-state module (remembers the window's position/size/maximized
  # state across restarts and, on first run, centers on the primary display). The
  # module is a standalone, public-API-only file dropped next to the bundled main
  # process; we then wire it into the window manager via an import + a single call
  # right after the main BrowserWindow is constructed.
  cp "${PROJECT_ROOT}/include/window-state.mjs" "$BUILD_DIR/app/.vite/build/window-state.mjs"

  node - "$BUILD_DIR/app/.vite/build" <<'NODE'
const fs = require('fs');
const path = require('path');
const buildDir = process.argv[2];

const importLine = 'import { installWindowState } from "./window-state.mjs";\n';
// `this.mainWindow` and `.constructorOptions` are semantic names the minifier
// keeps, so match the surrounding minified identifiers (BrowserWindow, config
// fn) with \w+ to stay resilient across upstream releases.
const anchorRe = /this\.mainWindow = new (\w+)\((\w+)\(\)\.constructorOptions\)/;

const candidates = fs
  .readdirSync(buildDir)
  .filter((n) => n.endsWith('.js'))
  .map((n) => path.join(buildDir, n));

const hits = candidates.filter((p) => anchorRe.test(fs.readFileSync(p, 'utf8')));

if (hits.length === 0) {
  console.error(`no JS file in ${buildDir} contains the main-window creation anchor`);
  console.error('  looked for: this.mainWindow = new <Win>(<cfg>().constructorOptions)');
  console.error('  the upstream app likely changed; window-state injection needs updating');
  process.exit(1);
}
if (hits.length > 1) {
  console.error(`ambiguous window-state anchor, matched multiple files: ${hits.join(', ')}`);
  process.exit(1);
}

const target = hits[0];
console.log(`injecting window-state into ${path.basename(target)}`);
let src = fs.readFileSync(target, 'utf8');

src = src.replace(anchorRe, (m) => `${m}, installWindowState(this.mainWindow)`);
if (!src.startsWith(importLine)) {
  src = importLine + src;
}

fs.writeFileSync(target, src);
NODE

  cp -a "$BUILD_DIR/payload/assets" "$BUILD_DIR/staged-assets"
  if [[ ! -f "$BUILD_DIR/staged-assets/TrayTemplate.png" ]]; then
    cp "$BUILD_DIR/staged-assets/AppList.targetsize-32.png" "$BUILD_DIR/staged-assets/TrayTemplate.png"
  fi

  mkdir -p "$BUILD_DIR/staged-electron"
  cp -a "${PROJECT_ROOT}/node_modules/electron/dist/." "$BUILD_DIR/staged-electron/"
  rm -f "$BUILD_DIR/staged-electron/resources/app.asar"
  "${PROJECT_ROOT}/node_modules/.bin/asar" pack "$BUILD_DIR/app" "$BUILD_DIR/staged-electron/resources/app.asar"
}

build_deb() {
  section "Build Debian Package"
  local pkg_root="$BUILD_DIR/pkgroot"
  local install_root="$pkg_root/opt/$PACKAGE_NAME"
  local bin_dir="$pkg_root/usr/bin"
  local app_dir="$pkg_root/usr/share/applications"
  local icon_dir="$pkg_root/usr/share/icons/hicolor/256x256/apps"

  mkdir -p "$install_root" "$bin_dir" "$app_dir" "$icon_dir" "$pkg_root/DEBIAN"
  cp -a "$BUILD_DIR/staged-electron" "$install_root/electron"
  cp -a "$BUILD_DIR/staged-assets" "$install_root/assets"

  # Electron derives the X11 WM_CLASS from the app's productName (e.g.
  # "ChatGPT Classic"), so the .desktop StartupWMClass must match that exact
  # string for GNOME to bind the running window to this launcher (correct icon
  # + name instead of a generic, icon-less entry). Read it from the app's own
  # package.json so it stays correct even if upstream renames the product.
  local wm_class
  wm_class="$(node -e 'process.stdout.write((require(process.argv[1]).productName||require(process.argv[1]).name||"electron"))' "$BUILD_DIR/app/package.json")"
  [[ -n "$wm_class" ]] || wm_class="electron"
  printf 'desktop StartupWMClass: %s\n' "$wm_class"

  # Rename the Electron binary so app.isPackaged is true on Linux (see note by
  # ELECTRON_BIN_NAME). Without this the system tray icon is invisible.
  mv "$install_root/electron/electron" "$install_root/electron/$ELECTRON_BIN_NAME"

  # No --no-sandbox: the Chromium sandbox stays enabled. It relies on the
  # chrome-sandbox helper being setuid-root, which the package's postinst sets
  # up at install time (see build_control below).
  cat > "$bin_dir/$PACKAGE_NAME" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec /opt/$PACKAGE_NAME/electron/$ELECTRON_BIN_NAME "\$@"
EOF
  chmod 0755 "$bin_dir/$PACKAGE_NAME"

  cat > "$bin_dir/${PACKAGE_NAME}-register" <<EOF
#!/usr/bin/env bash
set -euo pipefail

desktop_file="${PACKAGE_NAME}.desktop"

if ! command -v xdg-mime >/dev/null 2>&1; then
  echo "xdg-mime not found" >&2
  exit 1
fi

xdg-mime default "\$desktop_file" x-scheme-handler/chatgpt
xdg-mime default "\$desktop_file" x-scheme-handler/chatgpt-alt

echo "Registered URL handlers:"
echo "  chatgpt -> \$(xdg-mime query default x-scheme-handler/chatgpt)"
echo "  chatgpt-alt -> \$(xdg-mime query default x-scheme-handler/chatgpt-alt)"
EOF
  chmod 0755 "$bin_dir/${PACKAGE_NAME}-register"

  cp "$BUILD_DIR/staged-assets/AppList.targetsize-256.png" "$icon_dir/$PACKAGE_NAME.png"

  cat > "$app_dir/$PACKAGE_NAME.desktop" <<EOF
[Desktop Entry]
Name=ChatGPT
Comment=ChatGPT Desktop
Exec=$PACKAGE_NAME %u
Icon=$PACKAGE_NAME
Type=Application
Terminal=false
Categories=Utility;
StartupWMClass=$wm_class
X-GNOME-WMClass=$wm_class
MimeType=x-scheme-handler/chatgpt;x-scheme-handler/chatgpt-alt;
EOF

  cat > "$pkg_root/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Depends: libgtk-3-0, libnss3, libxss1, libasound2t64 | libasound2, libgbm1, libxshmfence1, libatk-bridge2.0-0, libdrm2, libxkbcommon0
Description: $DESCRIPTION
EOF

  cat > "$pkg_root/DEBIAN/postinst" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# The Chromium sandbox on Linux requires its helper binary to be owned by root
# with the setuid bit set. Without this the app either refuses to start or has
# to be launched with --no-sandbox (which disables the sandbox entirely). We
# set it here, as root, at install time instead. This mirrors what the official
# VS Code / Slack / Discord Electron packages do.
chrome_sandbox="/opt/$PACKAGE_NAME/electron/chrome-sandbox"
if [[ -f "\$chrome_sandbox" ]]; then
  chown root:root "\$chrome_sandbox"
  chmod 4755 "\$chrome_sandbox"
fi

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
EOF
  chmod 0755 "$pkg_root/DEBIAN/postinst"

  cat > "$pkg_root/DEBIAN/postrm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "remove" || "${1:-}" == "purge" ]]; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
EOF
  chmod 0755 "$pkg_root/DEBIAN/postrm"

  local out_file="$OUT_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
  dpkg-deb --build "$pkg_root" "$out_file" >/dev/null
  printf "built package: %s\n" "$out_file"
}

cleanup() {
  if [[ "$CLEAN" == "yes" ]]; then
    rm -rf "$BUILD_DIR"
  fi
}

main() {
  parse_args "$@"
  check_deps
  validate_input
  prepare_dirs
  detect_version
  extract_payload
  align_electron
  patch_app
  build_deb
  cleanup
}

main "$@"
