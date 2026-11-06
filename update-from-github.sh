#!/usr/bin/env bash
# Fetch the latest Tessentry main branch and apply its bundled updater.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run: sudo bash update-from-github.sh' >&2; exit 1; }
command -v curl >/dev/null && command -v python3 >/dev/null || { echo 'curl and python3 are required' >&2; exit 1; }
WORK="$(mktemp -d /mutable/tessentry-update.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
  'https://github.com/viko-repo/tessentry/archive/refs/heads/main.zip' -o "$WORK/source.zip"
python3 - "$WORK/source.zip" "$WORK" <<'PY'
import pathlib,sys,zipfile
archive=pathlib.Path(sys.argv[1]); root=pathlib.Path(sys.argv[2]).resolve()
with zipfile.ZipFile(archive) as z:
    for info in z.infolist():
        path=pathlib.PurePosixPath(info.filename)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!='tessentry-main':
            raise SystemExit('Unsafe ZIP path')
        if (info.external_attr >> 16) & 0o170000 == 0o120000:
            raise SystemExit('Symlink not allowed in ZIP')
    z.extractall(root)
PY
[[ -f "$WORK/tessentry-main/update.sh" ]] || { echo 'GitHub main has no update.sh; publish the updated project first' >&2; exit 1; }
bash "$WORK/tessentry-main/update.sh"
