#!/usr/bin/env bash
# Patch, check, build and install Slotstream from the source archive that ships with it.
#
#   scripts/build-slotstream.sh              full run: extract, patch, make checks, make build, install, restart
#   scripts/build-slotstream.sh --build-only  everything except install and restart (leaves the build in the work dir)
#   scripts/build-slotstream.sh --yes         do not ask before stopping the server
#   scripts/build-slotstream.sh --source DIR  use this source tree instead of the shipped archive
#   scripts/build-slotstream.sh --status      report whether the installed binary carries the patches, then exit
#
# The patches in patches/ are for Slotstream 0.2.14 exactly; the script refuses other versions.
# It never applies a patch twice: a patch that already applies in reverse is skipped.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$REPO/scripts/slotkeeper"
SLOTSTREAM_HOME="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
BIN="$SLOTSTREAM_HOME/bin"
PATCH_VERSION="0.2.14"
BUILD_ONLY=0; YES=0; SOURCE=""; STATUS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1 ;;
    --yes) YES=1 ;;
    --source) SOURCE="$2"; shift ;;
    --status) STATUS=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done
log() { printf '[build-slotstream %s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "error: $*"; exit 1; }

patch_status() {
  local exe="$BIN/slotstream"
  [[ -x "$exe" ]] || { echo "no installed binary at $exe"; return; }
  echo "installed: $("$exe" --version 2>/dev/null) at $(readlink "$BIN" 2>/dev/null || echo "$BIN")"
  # grep -q closes the pipe early; under pipefail that would read as "absent". Capture first.
  local dump; dump="$(strings "$exe" 2>/dev/null || true)"
  if grep -q "try your request again after memory becomes available" <<<"$dump"; then echo "  retry wording patch:   present"; else echo "  retry wording patch:   absent"; fi
  if grep -q "stale threshold" <<<"$dump"; then echo "  stale pressure patch:  present"; else echo "  stale pressure patch:  absent"; fi
}
if (( STATUS )); then patch_status; exit 0; fi

command -v swift >/dev/null || die "swift not found; install Xcode or the Command Line Tools"
command -v make >/dev/null || die "make not found"
[[ -x "$BIN/slotstream" ]] || die "no Slotstream at $BIN/slotstream"
version="$("$BIN/slotstream" --version 2>/dev/null | tr -d '[:space:]')"
[[ "$version" == "$PATCH_VERSION" ]] || die "installed Slotstream is $version; the patches target $PATCH_VERSION"
[[ -f "$BIN/mlx.metallib" ]] || die "no mlx.metallib beside the installed binary"

work="$SLOTSTREAM_HOME/build/slotstream-$PATCH_VERSION-$(date +%Y%m%d%H%M%S)"
mkdir -p "$work"
if [[ -n "$SOURCE" ]]; then
  log "copying source from $SOURCE"
  cp -R "$SOURCE"/. "$work"/
else
  archive=""
  for candidate in "$BIN/build-source.tar.gz.$PATCH_VERSION.original" "$BIN/build-source.tar.gz"; do
    [[ -f "$candidate" ]] && { archive="$candidate"; break; }
  done
  [[ -n "$archive" ]] || die "no build-source.tar.gz beside the installed binary; pass --source <dir>"
  log "extracting $archive"
  tar -xzf "$archive" -C "$work"
fi
[[ -f "$work/Makefile" && -d "$work/Sources" ]] || die "source tree at $work has no Makefile/Sources"
rm -rf "$work/.build"

log "applying patches"
applied=0
for p in "$REPO"/patches/*.patch; do
  name="$(basename "$p")"
  if (cd "$work" && patch --dry-run --forward --batch -p1 < "$p" >/dev/null 2>&1); then
    (cd "$work" && patch --forward --batch -p1 < "$p" >/dev/null)
    log "  applied $name"; applied=$((applied + 1))
  elif (cd "$work" && patch --dry-run --reverse --batch -p1 < "$p" >/dev/null 2>&1); then
    log "  already present: $name"
  else
    die "$name does not apply cleanly to this source; it may not be stock $PATCH_VERSION"
  fi
done
find "$work" -name '*.orig' -delete
mkdir -p "$work/Tools/lib" && cp "$BIN/mlx.metallib" "$work/Tools/lib/mlx-0.31.1.metallib"

log "make checks (debug build + T0 suite, a few minutes)"
(cd "$work" && make checks 2>&1 | tail -3 | sed 's/^/  /')
log "make build (release)"
(cd "$work" && make build 2>&1 | grep -E "Build complete|error" | sed 's/^/  /')
[[ -x "$work/.build/release/slotstream" ]] || die "release build missing"
log "built $("$work/.build/release/slotstream" --version) with $applied patch(es) newly applied"

if (( BUILD_ONLY )); then
  log "build-only: install later with  $REPO/scripts/install-release.sh $work"
  exit 0
fi

if (( ! YES )); then
  read -r -p "Install and restart the server now? Requests in flight will be interrupted. [y/N] " a
  [[ "$a" == y* ]] || { log "not installed; run: $REPO/scripts/install-release.sh $work"; exit 0; }
fi
[[ -f "$SLOTSTREAM_HOME/exerciser.state.json" ]] && "$CTL" exerciser pause "installing Slotstream build" >/dev/null 2>&1 || true
"$CTL" stop
"$REPO/scripts/install-release.sh" "$work"
"$CTL" start
"$CTL" exerciser resume >/dev/null 2>&1 || true
patch_status
log "done; previous release kept for  $REPO/scripts/install-release.sh --rollback <dir>"
