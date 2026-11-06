#!/usr/bin/env bash
# Download a chosen Tessentry version and run its bundled updater.
# Default: main. To use a release tag: sudo bash update-from-github.sh v1.2.0
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root (sudo)' >&2; exit 1; }
for cmd in curl python3; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }; done
mountpoint -q /mutable && [[ -w /mutable ]] || { echo '/mutable must be writable' >&2; exit 1; }
REF="${1:-main}"
if [[ "$REF" != main && ! "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'Use main or a version tag like v1.2.0' >&2; exit 1
fi
WORK="$(mktemp -d /mutable/tessentry-update.XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
if [[ "$REF" == main ]]; then
  URL='https://github.com/viko-repo/tessentry/archive/refs/heads/main.zip'
  TOP='tessentry-main'
else
  URL="https://github.com/viko-repo/tessentry/archive/refs/tags/$REF.zip"
  TOP="tessentry-$REF"
fi
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 "$URL" -o "$WORK/source.zip"
python3 - "$WORK/source.zip" "$WORK" "$TOP" <<'PY'
import pathlib, sys, zipfile
archive, root, top = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
with zipfile.ZipFile(archive) as z:
    total = 0
    for info in z.infolist():
        path = pathlib.PurePosixPath(info.filename)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != top:
            raise SystemExit('Unsafe ZIP path')
        mode = (info.external_attr >> 16) & 0o170000
        if mode not in (0, 0o100000, 0o040000):
            raise SystemExit('Unsupported ZIP entry type')
        total += info.file_size
        if total > 100 * 1024 * 1024:
            raise SystemExit('Archive too large')
    z.extractall(root)
PY
[[ -f "$WORK/$TOP/update.sh" ]] || { echo 'Release does not contain update.sh' >&2; exit 1; }
bash "$WORK/$TOP/update.sh"
