#!/usr/bin/env bash
# Install a freshly built Slotstream release as a new release directory and switch the
# ~/.slotstream/bin symlink to it. Follows SLOTSTREAM_RECOVERY.md "Rebuild Procedure":
# never overwrite the active release; the previous one stays for rollback.
#
# Usage: install-release.sh <source-tree-with-.build/release> [release-name]
#        install-release.sh --rollback <release-dir-name>     point bin at an earlier release
#        install-release.sh --list
#
# Stops nothing and starts nothing. Stop the server before running, then start it after.
set -euo pipefail
SLOTSTREAM_HOME="${SLOTSTREAM_HOME:-$HOME/.slotstream}"
RELEASES="$SLOTSTREAM_HOME/releases"
BIN="$SLOTSTREAM_HOME/bin"

switch() {
  local target="$1"
  ln -sfn "$target" "$SLOTSTREAM_HOME/bin.next"
  # -h: replace the symlink itself instead of moving into the directory it points at
  mv -fh "$SLOTSTREAM_HOME/bin.next" "$BIN"
  echo "bin -> $(readlink "$BIN")"
}

case "${1:-}" in
  --list) ls -1t "$RELEASES"; echo "current: $(readlink "$BIN")"; exit 0 ;;
  --rollback) [[ -d "$RELEASES/$2" ]] || { echo "no such release $2" >&2; exit 1; }; switch "$RELEASES/$2"; exit 0 ;;
esac

src="${1:?source tree}"
name="${2:-slotstream-0.2.14-local-$(date +%Y%m%d%H%M%S)}"
out="$src/.build/release"
for f in slotstream mlx.metallib build-identity.json; do [[ -f "$out/$f" ]] || { echo "missing $out/$f" >&2; exit 1; }; done
if pgrep -f "slotstream serve" >/dev/null; then echo "server is running; stop it first (scripts/slotkeeper stop)" >&2; exit 1; fi

release="$RELEASES/$name"
mkdir -p "$release"
install -m 755 "$out/slotstream" "$release/slotstream"
install -m 644 "$out/mlx.metallib" "$release/mlx.metallib"
install -m 644 "$out/build-identity.json" "$release/build-identity.json"
if [[ -f "$out/build-source.tar.gz" ]]; then
  install -m 644 "$out/build-source.tar.gz" "$release/build-source.tar.gz"
else
  # Reconstruct the source archive from the tree so the release stays self-describing.
  tar -czf "$release/build-source.tar.gz" -C "$src" --exclude .build --exclude 'Tools/lib' Makefile Package.swift Package.resolved Sources Tools
fi
"$release/slotstream" --version
echo "installed $release"
shasum -a 256 "$release"/slotstream "$release"/mlx.metallib "$release"/build-identity.json "$release"/build-source.tar.gz
switch "$release"
echo "previous release(s) kept in $RELEASES for --rollback"
