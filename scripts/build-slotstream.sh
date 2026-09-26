#!/usr/bin/env bash
# Patch, check, build and install Slotstream from the source archive that ships with it.
#
#   scripts/build-slotstream.sh              full run: extract, patch, make checks, make build, install, restart
#   scripts/build-slotstream.sh --build-only  everything except install and restart (leaves the build in the work dir)
#   scripts/build-slotstream.sh --yes         do not ask before stopping the server
#   scripts/build-slotstream.sh --source DIR  use this source tree instead of the shipped archive
#   scripts/build-slotstream.sh --version V   build Slotstream V (default: the source's version, else the installed one)
#   scripts/build-slotstream.sh --status      report whether the installed binary carries the patches, then exit
#
# Each version has its own patch stack, applied in the order patches/series-<version> gives.
# Stock source comes from the release it shipped with when that is the installed version,
# otherwise from the upstream tag. A patch that already applies in reverse is skipped.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$REPO/scripts/slotkeeper"
SLOTSTREAM_HOME="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
BIN="$SLOTSTREAM_HOME/bin"
PATCH_VERSION=""
BUILD_ONLY=0; YES=0; SOURCE=""; STATUS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) BUILD_ONLY=1 ;;
    --yes) YES=1 ;;
    --source) SOURCE="$2"; shift ;;
    --version) PATCH_VERSION="$2"; shift ;;
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
  if grep -q "prefix retention ceiling must be between" <<<"$dump"; then echo "  prefix retention patch: present"; else echo "  prefix retention patch: absent"; fi
  if grep -q "capped below the pool that met pressure" <<<"$dump"; then echo "  pressure ceiling patch: present"; else echo "  pressure ceiling patch: absent"; fi
  if grep -q "committed prompt tokens for a retry" <<<"$dump"; then echo "  resume-after-refusal patch: present"; else echo "  resume-after-refusal patch: absent"; fi
  if grep -q "beyond-qualified-context" <<<"$dump"; then echo "  window-beyond-qualified patch: present"; else echo "  window-beyond-qualified patch: absent"; fi
  if grep -q "SLOTSTREAM_AVAILABILITY_SLACK_GB" <<<"$dump"; then echo "  settable-headroom patch: present"; else echo "  settable-headroom patch: absent"; fi
  if grep -q "SLOTSTREAM_WORKING_SET_GB" <<<"$dump"; then echo "  working-set patch: present"; else echo "  working-set patch: absent"; fi
  if grep -q "this server keeps no completions" <<<"$dump"; then echo "  store-false patch: present"; else echo "  store-false patch: absent"; fi
  if grep -q "generated at %.2f tok/s" <<<"$dump"; then echo "  request-summary patch: present"; else echo "  request-summary patch: absent"; fi
}
if (( STATUS )); then patch_status; exit 0; fi

command -v swift >/dev/null || die "swift not found; install Xcode or the Command Line Tools"
command -v make >/dev/null || die "make not found"
installed="$("$BIN/slotstream" --version 2>/dev/null | tr -d '[:space:]' || true)"
source_version() { grep -oE '"[0-9]+\.[0-9]+\.[0-9]+"' "$1/Sources/Slotstream/Version.swift" 2>/dev/null | head -1 | tr -d '"'; }
[[ -n "$SOURCE" && -z "$PATCH_VERSION" ]] && PATCH_VERSION="$(source_version "$SOURCE")"
PATCH_VERSION="${PATCH_VERSION:-$installed}"
[[ -n "$PATCH_VERSION" ]] || die "cannot tell which Slotstream version to build; pass --version"
SERIES="$REPO/patches/series-$PATCH_VERSION"
[[ -f "$SERIES" ]] || die "no patches/series-$PATCH_VERSION: the patch stack has not been ported to $PATCH_VERSION"

work="$SLOTSTREAM_HOME/build/slotstream-$PATCH_VERSION-$(date +%Y%m%d%H%M%S)"
mkdir -p "$work"
if [[ -n "$SOURCE" ]]; then
  log "copying source from $SOURCE"
  cp -R "$SOURCE"/. "$work"/
elif [[ "$installed" == "$PATCH_VERSION" ]]; then
  archive=""
  # The stock archive stays with the release it came from, not with whichever release
  # $BIN points at now; the installed build-source.tar.gz is already patched.
  for candidate in "$BIN/build-source.tar.gz.$PATCH_VERSION.original" \
      "$SLOTSTREAM_HOME"/releases/*/build-source.tar.gz."$PATCH_VERSION".original "$BIN/build-source.tar.gz"; do
    [[ -f "$candidate" ]] && { archive="$candidate"; break; }
  done
  [[ -n "$archive" ]] || die "no build-source.tar.gz beside the installed binary; pass --source <dir>"
  log "extracting $archive"
  tar -xzf "$archive" -C "$work"
else
  log "fetching stock $PATCH_VERSION from github.com/carloslfu/slotstream (tag v$PATCH_VERSION)"
  git clone -q --depth 1 --branch "v$PATCH_VERSION" https://github.com/carloslfu/slotstream "$work" \
    || die "could not fetch v$PATCH_VERSION"
  rm -rf "$work/.git"
fi
[[ "$(source_version "$work")" == "$PATCH_VERSION" ]] || die "the source at $work is not $PATCH_VERSION"
[[ -f "$work/Makefile" && -d "$work/Sources" ]] || die "source tree at $work has no Makefile/Sources"
rm -rf "$work/.build"

log "applying patches"
# The series file gives the order: later patches are written on top of earlier ones, and
# alphabetical order put settable-headroom and working-set before window-beyond-qualified.
series=()
while read -r n; do
  [[ -z "$n" || "$n" == \#* ]] && continue
  [[ -f "$REPO/patches/$n" ]] || die "$(basename "$SERIES") names $n, which does not exist"
  series+=("$REPO/patches/$n")
done < "$SERIES"
for p in "$REPO"/patches/slotstream-"$PATCH_VERSION"-*.patch; do
  [[ -e "$p" ]] || continue
  grep -qxF "$(basename "$p")" "$SERIES" || die "$(basename "$p") is not in $(basename "$SERIES")"
done
applied=0
for p in "${series[@]}"; do
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
# The installed metallib only matches a rebuild of the same version; otherwise make fetches
# the one the Makefile names (0.2.14 used mlx-0.31.1, 0.2.25 uses mlx-0.32.2).
metallib="$(sed -n 's/^METALLIB *:\{0,1\}= *//p' "$work/Makefile" | head -1)"
if [[ "$installed" == "$PATCH_VERSION" && -n "$metallib" && -f "$BIN/mlx.metallib" ]]; then
  mkdir -p "$work/$(dirname "$metallib")" && cp "$BIN/mlx.metallib" "$work/$metallib"
fi

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
