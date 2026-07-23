#!/usr/bin/env bash
#
# sync-to-clip.sh — Mirror this repo into Seeed-Studio/reSpeaker_Clip under
# mobile/ as a one-directional downstream copy.
#
# github.com/skye-xiao/sensecraft-voice stays the single source of truth.
# This script does NOT import history; it snapshots the *committed* HEAD of
# this repo into <reSpeaker_Clip>/mobile/ and makes a single commit on a
# feature branch in the reSpeaker_Clip checkout. Pushing / opening the PR is
# left to you (reSpeaker_Clip is a shared org repo).
#
# What it does:
#   1. Snapshot this repo's tracked files at HEAD (git archive) — clean, no
#      build/, .dart_tool/, .git, or other ignored artifacts.
#   2. Replace <clip>/mobile/ wholesale so deletions in the source propagate.
#   3. git add -f mobile   (force: reSpeaker_Clip's root .gitignore has broad
#      rules like *.log / *.wav / *.opus / Makefile that would otherwise drop
#      legitimate mobile files).
#   4. Commit on branch sync/mobile-<sha> if anything changed.
#
# Usage:
#   scripts/sync-to-clip.sh [RESPEAKER_CLIP_PATH]
#
# RESPEAKER_CLIP_PATH defaults to the sibling ../reSpeaker_Clip.
# Override the subdir with MOBILE_SUBDIR=... and the branch with BRANCH=...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLIP="${1:-$REPO_ROOT/../reSpeaker_Clip}"
MOBILE_SUBDIR="${MOBILE_SUBDIR:-mobile}"

if [[ ! -d "$CLIP/.git" ]]; then
  echo "error: reSpeaker_Clip checkout not found (no .git): $CLIP" >&2
  echo "usage: scripts/sync-to-clip.sh [RESPEAKER_CLIP_PATH]" >&2
  echo "hint : git clone git@github.com:Seeed-Studio/reSpeaker_Clip.git" >&2
  exit 1
fi
CLIP="$(cd "$CLIP" && pwd)"

# Snapshot the committed HEAD, so warn on a dirty source tree.
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "warn: this repo has uncommitted changes; snapshot uses HEAD, not the" >&2
  echo "      working tree. Commit here first if you want them included." >&2
fi

SRC_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
BRANCH="${BRANCH:-sync/mobile-$SRC_SHA}"
DEST="$CLIP/$MOBILE_SUBDIR"

echo "==> Source     : $REPO_ROOT @ $SRC_SHA"
echo "==> reSpeaker  : $CLIP"
echo "==> Dest subdir: $MOBILE_SUBDIR/"
echo "==> Branch     : $BRANCH"

echo "==> Preparing branch in reSpeaker_Clip ..."
git -C "$CLIP" fetch origin main --quiet || true
if git -C "$CLIP" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$CLIP" checkout --quiet "$BRANCH"
else
  # Base off origin/main when available, else current HEAD.
  if git -C "$CLIP" show-ref --verify --quiet refs/remotes/origin/main; then
    git -C "$CLIP" checkout --quiet -b "$BRANCH" origin/main
  else
    git -C "$CLIP" checkout --quiet -b "$BRANCH"
  fi
fi

echo "==> Snapshotting HEAD into $MOBILE_SUBDIR/ ..."
rm -rf "$DEST"
mkdir -p "$DEST"
git -C "$REPO_ROOT" archive --format=tar HEAD | tar -x -C "$DEST"

echo "==> Staging (force, to bypass reSpeaker_Clip root .gitignore) ..."
git -C "$CLIP" add -f "$MOBILE_SUBDIR"

if git -C "$CLIP" diff --cached --quiet; then
  echo "==> No changes to commit; $MOBILE_SUBDIR/ already matches $SRC_SHA."
  exit 0
fi

git -C "$CLIP" commit --quiet -m "chore($MOBILE_SUBDIR): sync from sensecraft-voice @$SRC_SHA"

STAGED_COUNT="$(git -C "$CLIP" show --stat --oneline HEAD | tail -1 || true)"
cat <<EOF

==> Done. $MOBILE_SUBDIR/ in reSpeaker_Clip now matches sensecraft-voice @$SRC_SHA.
    Commit: $(git -C "$CLIP" log --oneline -1)

Next (push + PR are manual — shared org repo):
  git -C "$CLIP" push -u origin "$BRANCH"
  # then open a PR against main:
  #   https://github.com/Seeed-Studio/reSpeaker_Clip/compare/main...$BRANCH
EOF
