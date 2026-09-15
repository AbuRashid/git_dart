#!/usr/bin/env bash
# Builds the hosted sandbox demo as one zip, ready to upload as a takhzeen app.
#
#   tool/build_demo.sh <app-slug>
#
# The zip holds the web build of lib/main_demo.dart and gitexplorer.bundle, a
# git bundle of this repository's committed history. The app seeds a visitor's
# browser from the bundle, and offers the same file as "Get the code". Nothing
# uncommitted goes into it.
#
# Takhzeen serves the app from /apps/<slug>/, which is what the base href is
# set to, and refuses uploads over 25 MB — checked here rather than found out
# at the upload.
set -euo pipefail

slug="${1:?usage: tool/build_demo.sh <app-slug>}"
app="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(git -C "$app" rev-parse --show-toplevel)"
out="$app/build/web"
zip="$app/build/demo.zip"
limit=$((25 * 1024 * 1024))

size_of() { wc -c < "$1" | tr -d ' '; }
megabytes() { awk -v b="$1" 'BEGIN { printf "%.1f MB", b / 1048576 }'; }

if [ -n "$(git -C "$repo" status --porcelain)" ]; then
  echo "note: the working tree has uncommitted changes; the bundle carries commits only" >&2
fi

cd "$app"
# MSYS_NO_PATHCONV: Git Bash otherwise rewrites /apps/<slug>/ into a Windows
# path before Flutter sees it. Ignored everywhere else.
MSYS_NO_PATHCONV=1 flutter build web --release --target lib/main_demo.dart \
  --base-href "/apps/$slug/"

# Debugging symbols for the renderer: megabytes nobody visiting needs.
find "$out" -name '*.symbols' -delete

bundle="$out/gitexplorer.bundle"
git -C "$repo" bundle create "$bundle" HEAD --branches --tags
git -C "$repo" bundle verify "$bundle" > /dev/null
echo "bundle: $(megabytes "$(size_of "$bundle")")"

rm -f "$zip"
(
  cd "$out"
  if command -v zip > /dev/null; then
    zip -qr ../demo.zip . -x .last_build_id
  elif [ -x /c/Windows/System32/tar.exe ]; then
    # Git Bash has no zip, but Windows' own bsdtar writes one. Named entries
    # rather than ".", which would prefix every path in the archive with ./
    /c/Windows/System32/tar.exe -a -c -f ../demo.zip -- *
  else
    echo "error: no zip tool found" >&2
    exit 1
  fi
)

size="$(size_of "$zip")"
echo "zip: $(megabytes "$size") -> $zip"
if [ "$size" -gt "$limit" ]; then
  echo "error: over takhzeen's 25 MB upload limit" >&2
  exit 1
fi
