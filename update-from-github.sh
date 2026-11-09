
#!/usr/bin/env bash
# Tessentry v1.3.0 - GitHub updater.
# Downloads the selected version and runs its bundled update.sh.
#
# Usage:
#   sudo bash update-from-github.sh
#   sudo bash update-from-github.sh v1.3.0
#
# Default branch: main

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
  echo "ERROR: Run as root (sudo)" >&2
  exit 1
}

for cmd in curl python3 mktemp mountpoint; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Missing required command: $cmd" >&2
    exit 1
  }
done

mountpoint -q /mutable && [[ -w /mutable ]] || {
  echo "ERROR: /mutable must be mounted and writable" >&2
  exit 1
}

REF="${1:-main}"

if [[ "$REF" != "main" &&
      ! "$REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Use main or a version tag such as v1.3.0" >&2
  exit 1
fi

WORK="$(mktemp -d /mutable/tessentry-update.XXXXXXXX)"

cleanup() {
  rm -rf -- "$WORK"
}

trap cleanup EXIT

if [[ "$REF" == "main" ]]; then
  URL="https://github.com/viko-repo/tessentry/archive/refs/heads/main.zip"
  TOP="tessentry-main"
else
  URL="https://github.com/viko-repo/tessentry/archive/refs/tags/${REF}.zip"
  TOP="tessentry-${REF}"
fi

echo "=============================================="
echo "TESSENTRY GITHUB UPDATER"
echo "=============================================="
echo "Source: $REF"
echo "Downloading application..."

curl \
  --fail \
  --location \
  --silent \
  --show-error \
  --retry 3 \
  --connect-timeout 15 \
  --max-time 180 \
  "$URL" \
  -o "$WORK/source.zip"

echo "Validating downloaded archive..."

python3 - "$WORK/source.zip" "$WORK" "$TOP" <<'PY'
import pathlib
import sys
import zipfile

archive = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
top = sys.argv[3]

with zipfile.ZipFile(archive) as z:
    total = 0

    for info in z.infolist():
        path = pathlib.PurePosixPath(info.filename)

        if (
            path.is_absolute()
            or '..' in path.parts
            or not path.parts
            or path.parts[0] != top
        ):
            raise SystemExit('ERROR: Unsafe ZIP path')

        mode = (info.external_attr >> 16) & 0o170000

        if mode not in (0, 0o100000, 0o040000):
            raise SystemExit('ERROR: Unsupported ZIP entry type')

        total += info.file_size

        if total > 100 * 1024 * 1024:
            raise SystemExit('ERROR: Archive too large')

    z.extractall(root)

print('Archive validation: OK')
PY

PROJECT="$WORK/$TOP"

for file in \
  update.sh \
  tessentry/core.py \
  tessentry/web.py \
  tessentry/__main__.py \
  tessentry/locales/en.json \
  tessentry/locales/he.json
do
  [[ -f "$PROJECT/$file" ]] || {
    echo "ERROR: Missing project file: $file" >&2
    exit 1
  }
done

echo "Project files verified."
echo "Starting Tessentry update..."
echo

bash "$PROJECT/update.sh"

echo
echo "=============================================="
echo "TESSENTRY GITHUB UPDATE FINISHED"
echo "=============================================="
echo "Source: $REF"
echo "Temporary files will be removed."
echo "=============================================="
