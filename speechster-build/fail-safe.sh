#!/usr/bin/env bash
# fail-safe.sh - snapshot & rollback helpers

# Usage:
# fs_snapshot "desc" => returns variable SNAPSHOT_HASH and SNAPSHOT_BRANCH
# fs_rollback => roll back to snapshot
SNAPSHOT_BRANCH=""
SNAPSHOT_HASH=""

fs_snapshot() {
  SNAPSHOT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-branch")
  SNAPSHOT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "")
  echo "[snapshot] branch=${SNAPSHOT_BRANCH} hash=${SNAPSHOT_HASH}"
}

fs_rollback() {
  if [ -n "${SNAPSHOT_HASH}" ]; then
    echo "[rollback] resetting to ${SNAPSHOT_HASH} on branch ${SNAPSHOT_BRANCH}"
    git reset --hard "${SNAPSHOT_HASH}" || true
    git checkout "${SNAPSHOT_BRANCH}" || true
  else
    echo "[rollback] no snapshot available"
  fi
}
