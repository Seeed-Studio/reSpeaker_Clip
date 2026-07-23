#!/usr/bin/env bash
#
# sync-app.sh — Mirror the product Flutter app (developed on GitLab) into this
# monorepo's app/ directory as a one-directional downstream copy.
#
# GitLab stays the single source of truth for app code. This script does NOT
# import GitLab history; it snapshots the current working tree of the source
# repo into app/ and lets you create a single commit here.
#
# What it does:
#   1. rsync the source working tree into app/ (respects the source .gitignore,
#      drops build artifacts, .git, editor dirs).
#   2. Rewrite app/pubspec.yaml so the sensecraft_voice dependency points at the
#      in-repo SDK (path: ../sdk/flutter) instead of a git URL.
#   3. Regenerate app/pubspec.lock via `flutter pub get` (best effort).
#
# Usage:
#   scripts/sync-app.sh [SOURCE_REPO_PATH]
#
# SOURCE_REPO_PATH defaults to the sibling ../respeaker-app of this monorepo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="${1:-$REPO_ROOT/../respeaker-app}"
DEST="$REPO_ROOT/app"

if [[ ! -d "$SRC" ]]; then
  echo "error: source repo not found: $SRC" >&2
  echo "usage: scripts/sync-app.sh [SOURCE_REPO_PATH]" >&2
  exit 1
fi

SRC="$(cd "$SRC" && pwd)"

if [[ ! -f "$SRC/pubspec.yaml" ]]; then
  echo "error: $SRC does not look like a Flutter app (no pubspec.yaml)" >&2
  exit 1
fi

echo "==> Source : $SRC"
echo "==> Dest   : $DEST"

SRC_SHA="unknown"
if git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
  SRC_SHA="$(git -C "$SRC" rev-parse --short HEAD)"
  SRC_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  echo "==> Source rev: $SRC_BRANCH @ $SRC_SHA"
fi

mkdir -p "$DEST"

echo "==> Syncing working tree (respecting .gitignore) ..."
rsync -a --delete \
  --exclude='.git/' \
  --exclude='.DS_Store' \
  --exclude='.cursor/' \
  --exclude='.idea/' \
  --filter=':- .gitignore' \
  "$SRC/" "$DEST/"

PUBSPEC="$DEST/pubspec.yaml"
if [[ -f "$PUBSPEC" ]]; then
  echo "==> Rewriting sensecraft_voice dependency to local path (../sdk/flutter) ..."
  perl -0777 -i -pe \
    's/^  sensecraft_voice:\n(?:    .*\n)+/  sensecraft_voice:\n    path: ..\/sdk\/flutter\n/m' \
    "$PUBSPEC"
fi

echo "==> Regenerating pubspec.lock (flutter pub get) ..."
if command -v flutter >/dev/null 2>&1; then
  ( cd "$DEST" && flutter pub get ) || \
    echo "warn: 'flutter pub get' failed; run it manually inside app/ later." >&2
else
  echo "warn: flutter not found on PATH; skip pub get. Run it manually in app/." >&2
fi

cat <<EOF

==> Done. app/ now mirrors $SRC ($SRC_SHA).

Review, then commit here, e.g.:
  git add app
  git commit -m "chore(app): sync product app from gitlab @$SRC_SHA"
EOF
