#!/usr/bin/env bash
# esp-build.sh - Speechster Build System V4 (single-file, Level 3)
# One-file build manager: interactive OR fully flag-driven CI mode.
# Verbose by default. Use --quiet to disable (or export SPEECHSTER_VERBOSE=0).
#
# Quick examples:
#  ./esp-build.sh                          -> interactive (verbose)
#  ./esp-build.sh --track A --version 10.3 --env F --stability s --change + --parent A9.1 --commit-msg "msg"
#  ./esp-build.sh --auto --auto-parent --no-flash --no-commit --quiet   -> fully automated dry CI flow
#
# Requirements: bash, git, idf.py (ESP-IDF in PATH), coreutils, awk, sed
# Place at firmware repo root. Make executable: chmod +x esp-build.sh
set -euo pipefail

# -------------------------
# Defaults & env
# -------------------------
SPEECHSTER_VERBOSE=${SPEECHSTER_VERBOSE:-1}   # default verbose on
QUIET=0
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HISTORY_FILE="${ROOT_DIR}/build_history.txt"
CONFIG_FILE="${ROOT_DIR}/.speechster.conf"
DEFAULT_PORT="/dev/ttyACM0"
DEFAULT_ENV="F"
DEFAULT_TRACK="A"
SERIES_STRATEGY="major"   # major-branch strategy (A10, A11, B1, ...)
UNSAFE_MODE=0             # --dangerous
DRY_RUN=0                 # --dry
NO_FLASH=0
NO_MONITOR=0
NO_COMMIT=0
AUTO_MODE=0               # --auto (auto version + parent if possible)
AUTO_SUGGEST=0            # --auto-suggest (suggest version, still prompts unless --auto)
AUTO_PARENT=0             # --auto-parent (fill parent from last history)
FORCE_YES=0               # --yes to accept prompts
PORT="${DEFAULT_PORT}"
USE_UNICODE_PARENTS=1     # if 0, use <<A9.1>>
SPINNER_PID=0
NO_PARENT_FLAG=0
NO_ROLLBACK=0

# -------------------------
# ANSI colors & small helpers
# -------------------------
GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; CYAN="\e[36m"; BOLD="\e[1m"; RESET="\e[0m"
timestamp(){ date "+%Y-%m-%d %H:%M:%S"; }

ok(){ if [ "${SPEECHSTER_VERBOSE}" -eq 1 ]; then printf "${GREEN}[OK]${RESET} %s\n" "$*"; else printf "[OK] %s\n" "$*"; fi; }
info(){ if [ "${SPEECHSTER_VERBOSE}" -eq 1 ]; then printf "${CYAN}[INFO]${RESET} %s\n" "$*"; else printf "[INFO] %s\n" "$*"; fi; }
warn(){ if [ "${SPEECHSTER_VERBOSE}" -eq 1 ]; then printf "${YELLOW}[WARN]${RESET} %s\n" "$*"; else printf "[WARN] %s\n" "$*"; fi; }
err(){ if [ "${SPEECHSTER_VERBOSE}" -eq 1 ]; then printf "${RED}[ERR]${RESET} %s\n" "$*"; else printf "[ERR] %s\n" "$*"; fi; }

die(){ err "$*"; exit 1; }

# -------------------------
# Usage
# -------------------------
usage(){
cat <<EOF
Usage: $0 [options]

Level-3 (CI) capable flags:
  --track <A|B|R>            Track (A/B/R)
  --version <major.minor>    Version (eg 10.3)
  --env <F|W|B|T|M>         Environment (Firmware/Web/Backend/Tools/Multi)
  --stability <s|t|e|p|d|x>  Stability (s=stable,t=test,e=experimental,p=prototype,d=debug,x=broken)
  --change <+|*|%|!|~|=|?>   Change type (+ feature, * modify, % perf, ! breaking, ~ minor, = meta, ? misc)
  --parent <A9.1>           Parent build (optional)
  --no-parent               Explicitly no parent
  --port /dev/ttyXXX        Serial port for idf.py (default ${DEFAULT_PORT})

Automation & CI:
  --auto                    Full auto (auto-version + auto-parent + minimal prompts)
  --auto-suggest            Suggest next version (still prompts)
  --auto-parent             Fill parent from last build if available
  --commit-msg "message"    Commit message to use (auto if absent)
  --no-commit               Do not git commit
  --no-flash                Build only, do not flash
  --no-monitor              Build + flash, but no monitor
  --dry                     Dry-run: no git/idf actions; prints actions
  --dangerous               Allow risky ops without prompts (use carefully)
  --yes                     Answer yes to confirmation prompts
  --quiet, -q               Quiet mode (no verbose logs)
  --help, -h                Show this help

Examples:
  $0 --track A --version 10.3 --env F --stability s --change + --parent A9.1
  $0 --auto --env F --change + --commit-msg "Auto build" --no-flash

EOF
}

# -------------------------
# CLI parse
# -------------------------
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0;;
    --quiet|-q) SPEECHSTER_VERBOSE=0; QUIET=1; shift;;
    --dry) DRY_RUN=1; shift;;
    --dangerous) UNSAFE_MODE=1; shift;;
    --auto) AUTO_MODE=1; AUTO_SUGGEST=1; AUTO_PARENT=1; shift;;
    --auto-suggest) AUTO_SUGGEST=1; shift;;
    --auto-parent) AUTO_PARENT=1; shift;;
    --no-flash) NO_FLASH=1; shift;;
    --no-monitor) NO_MONITOR=1; shift;;
    --no-commit) NO_COMMIT=1; shift;;
    --yes) FORCE_YES=1; shift;;
    --track) TRACK="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --env) ENVIRONMENT="$2"; shift 2;;
    --stability) STABILITY="$2"; shift 2;;
    --change) CHANGETYPE="$2"; shift 2;;
    --parent) PARENT="$2"; shift 2;;
    --no-parent) PARENT=""; NO_PARENT_FLAG=1; shift;;
    --port) PORT="$2"; shift 2;;
    --commit-msg) COMMIT_MSG="$2"; shift 2;;
    --no-rollback) NO_ROLLBACK=1; shift;;
    -t) TRACK="$2"; shift 2;;
    -v) VERSION="$2"; shift 2;;
    -e) ENVIRONMENT="$2"; shift 2;;
    -s) STABILITY="$2"; shift 2;;
    -c) CHANGETYPE="$2"; shift 2;;
    -P) PARENT="$2"; shift 2;;
    *) ARGS+=("$1"); shift;;
  esac
done

# -------------------------
# utility functions
# -------------------------
is_valid_track(){ [[ "$1" =~ ^[ABR]$ ]]; }
is_valid_version(){ [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
is_valid_env(){ [[ "$1" =~ ^(F|W|B|T|M)$ ]]; }
is_valid_stability(){ [[ "$1" =~ ^(s|t|e|p|d|x)$ ]]; }
is_valid_change(){ [[ "$1" =~ ^(\+|\*|%|!|~|=|\?)$ ]]; }

# safe echo of parent with chosen bracket style
parent_bracketed(){ local p="$1"; if [ "${USE_UNICODE_PARENTS}" -eq 1 ]; then printf "⟪%s⟫" "$p"; else printf "<<%s>>" "$p"; fi }

# spinner (lightweight)
spinner_start(){
  if [ "${SPEECHSTER_VERBOSE}" -eq 1 ]; then
    ( while :; do for c in '/-\|'; do printf "\r[BUILD] %s " "$c"; sleep 0.08; done; done ) &
    SPINNER_PID=$!
    disown
  fi
}
spinner_stop(){
  if [ "${SPINNER_PID}" -ne 0 ] 2>/dev/null; then kill "$SPINNER_PID" 2>/dev/null || true; SPINNER_PID=0; printf "\r"; fi
}

# -------------------------
# History & config helpers
# -------------------------
load_defaults_and_config(){
  # defaults
  DEFAULT_ENV="${DEFAULT_ENV:-${DEFAULT_ENV}}"
  DEFAULT_PORT="${DEFAULT_PORT:-${PORT:-/dev/ttyACM0}}"
  DEFAULT_TRACK="${DEFAULT_TRACK:-A}"
  SERIES_STRATEGY="${SERIES_STRATEGY:-major}"
  [ -f "${CONFIG_FILE}" ] && source "${CONFIG_FILE}" || true
  # normalize
  PORT="${PORT:-${DEFAULT_PORT}}"
}

suggest_next_version(){
  local last="$1"
  [ -z "$last" ] && echo "1.0" && return
  last="${last#[A-Za-z]}"
  if ! is_valid_version "$last"; then echo "1.0"; return; fi
  IFS='.' read -r major minor <<< "$last"
  minor=${minor:-0}
  minor=$((minor + 1))
  echo "${major}.${minor}"
}

get_last_history_line(){
  [ -f "${HISTORY_FILE}" ] && tail -n 1 "${HISTORY_FILE}" || echo ""
}

extract_parent_from_history(){
  local line="$1"

  # Unicode bracket (⟪ ⟫)
  if [[ "$line" =~ ⟪([^⟫]+)⟫ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  # ASCII bracket << >>
  if [[ "$line" =~ \<\<([^>]+)\>\> ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi

  echo ""
}

# -------------------------
# bootstrap if empty repo
# -------------------------
bootstrap_if_needed(){
  if [ ! -d .git ]; then
    info "No git repo found. Bootstrapping..."
    git init
    # create minimal files so repo isn't empty
    mkdir -p main components docs || true
    echo "# Speechster Firmware - bootstrap" > README.md
    git add .
    git commit -m "Initial commit (speechster bootstrap)" || true
    git branch -M main || true
    ok "Bootstrapped git repo with main branch."
  fi
  # ensure main exists
  if ! git show-ref --verify --quiet refs/heads/main; then
    git checkout -b main || true
  fi
  # ensure history file exists
  touch "${HISTORY_FILE}"
}

# -------------------------
# git snapshot & rollback
# -------------------------
SNAPSHOT_BRANCH=""
SNAPSHOT_HASH=""
make_snapshot(){
  SNAPSHOT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-branch")
  SNAPSHOT_HASH=$(git rev-parse HEAD 2>/dev/null || echo "")
  info "Snapshot saved: branch=${SNAPSHOT_BRANCH} hash=${SNAPSHOT_HASH}"
}
rollback_snapshot(){
  if [ -n "$SNAPSHOT_HASH" ]; then
    warn "Rolling back to snapshot ${SNAPSHOT_HASH} on ${SNAPSHOT_BRANCH}"
    git reset --hard "${SNAPSHOT_HASH}" || true
    git checkout "${SNAPSHOT_BRANCH}" || true
  else
    warn "No snapshot to roll back to."
  fi
}

# -------------------------
# git helpers
# -------------------------
git_branch_exists(){ git show-ref --verify --quiet "refs/heads/$1"; return $?; }
git_checkout_or_create_branch(){
  local branch="$1"
  if git_branch_exists "$branch"; then
    info "[git] checkout $branch"
    git checkout "$branch"
  else
    info "[git] create branch $branch from main"
    git checkout -b "$branch" main
  fi
}
git_safe_commit(){
  local msg="$1"
  if [ "${DRY_RUN}" -eq 1 ]; then info "[dry] git add/commit -m \"$msg\""; return; fi
  git add -A
  git commit -a -m "$msg" || info "[git] commit returned non-zero (maybe nothing to commit)"
}
git_tag_build(){
  local tag="$1"; local message="$2"
  if [ "${DRY_RUN}" -eq 1 ]; then info "[dry] git tag -a $tag -m \"$message\""; return; fi
  git tag -a "$tag" -m "$message" || info "[git] tag may already exist"
}
git_merge_branch_into(){
  local src="$1"; local dst="$2"
  if [ "${DRY_RUN}" -eq 1 ]; then info "[dry] git checkout $dst && git merge $src"; return; fi
  git checkout "$dst"
  # prefer fast-forward
  if git merge --ff-only "$src" 2>/dev/null; then
    info "Fast-forwarded $dst with $src"
  else
    git merge "$src" || { err "Merge failed"; return 1; }
  fi
}
git_get_short_hash(){ git rev-parse --short HEAD 2>/dev/null || echo "no-hash"; }

# -------------------------
# version tag composition & validation
# -------------------------
make_version_tag(){
  local track="$1"; local version="$2"; local env="$3"; local stab="$4"; local ch="$5"; local parent="$6"
  if [ -z "$parent" ]; then
    printf "%s%s[%s|%s|%s]" "$track" "$version" "$env" "$stab" "$ch"
  else
    printf "%s%s[%s|%s|%s]::%s" "$track" "$version" "$env" "$stab" "$ch" "$(parent_bracketed "$parent")"
  fi
}

# -------------------------
# interactive helpers
# -------------------------
confirm_or_die(){
  local prompt="$1"
  if [ "${FORCE_YES}" -eq 1 ]; then return 0; fi
  read -p "$prompt (Y/n): " ans
  ans=${ans:-Y}
  if [[ ! "$ans" =~ ^[Yy] ]]; then die "User aborted"; fi
}

# -------------------------
# auto-suggestions & parent filling
# -------------------------
last_history_line=$(get_last_history_line)
LAST_VERSION_FROM_HISTORY=""
if [ -n "$last_history_line" ]; then
  # parse like: "2025-12-05 13:02 A10.3[F|s|+]::⟪A9.1⟫ commit=abc"
  if [[ "$last_history_line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    # extract second field
    LVER="$(echo "$last_history_line" | awk '{print $3}')"
    LAST_VERSION_FROM_HISTORY="$LVER"
  fi
fi

if [ "${AUTO_PARENT}" -eq 1 ] && [ -n "${LAST_VERSION_FROM_HISTORY}" ]; then
  auto_parent_candidate="$(extract_parent_from_history "${last_history_line}")"
  [ -n "$auto_parent_candidate" ] && info "Auto-parent filled from history: $auto_parent_candidate"
  PARENT="${PARENT:-$auto_parent_candidate}"
fi

# -------------------------
# Interactive prompts (if flags missing)
# -------------------------
# prompt for missing values (interactive unless fully automated with flags)
if [ -z "${TRACK:-}" ]; then
  read -p "Track (A/B/R) [${DEFAULT_TRACK}]: " TRACK
  TRACK=${TRACK:-$DEFAULT_TRACK}
fi
if ! is_valid_track "$TRACK"; then die "Invalid track: $TRACK"; fi

if [ -z "${VERSION:-}" ]; then
  if [ -n "${LAST_VERSION_FROM_HISTORY}" ] && [ "${AUTO_SUGGEST}" -eq 1 ]; then
    suggested_next=$(suggest_next_version "${LAST_VERSION_FROM_HISTORY}")
    read -p "Version (e.g. ${suggested_next}): " VERSION
    VERSION=${VERSION:-$suggested_next}
  else
    read -p "Version (e.g. 10.3): " VERSION
  fi
fi
if ! is_valid_version "$VERSION"; then die "Invalid version format: $VERSION"; fi

if [ -z "${ENVIRONMENT:-}" ]; then
  read -p "Environment (F/W/B/T/M) [${DEFAULT_ENV}]: " ENVIRONMENT
  ENVIRONMENT=${ENVIRONMENT:-$DEFAULT_ENV}
fi
if ! is_valid_env "$ENVIRONMENT"; then die "Invalid environment: $ENVIRONMENT"; fi

if [ -z "${STABILITY:-}" ]; then
  read -p "Stability (s/t/e/p/d/x) [t]: " STABILITY
  STABILITY=${STABILITY:-t}
fi
if ! is_valid_stability "$STABILITY"; then die "Invalid stability: $STABILITY"; fi

if [ -z "${CHANGETYPE:-}" ]; then
  read -p "Change Type (+/*/%/!/~/=/?): " CHANGETYPE
fi
if ! is_valid_change "${CHANGETYPE}"; then die "Invalid change type: ${CHANGETYPE}"; fi

# If user explicitly said --no-parent, never prompt.
if [ "${NO_PARENT_FLAG:-0}" -eq 1 ]; then
  PARENT=""
# Otherwise prompt only if needed.
elif [ -z "${PARENT:-}" ] && [ "${AUTO_PARENT}" -eq 0 ] && [ "${AUTO_MODE}" -eq 0 ]; then
  read -p "Parent (leave empty if none): " PARENT
fi

# -------------------------
# Compose tag and pre-checks
# -------------------------
VERSION_TAG="$(make_version_tag "$TRACK" "$VERSION" "$ENVIRONMENT" "$STABILITY" "$CHANGETYPE" "${PARENT:-}")"
info "Generated version tag: ${VERSION_TAG}"
echo "${VERSION_TAG}" > "${ROOT_DIR}/build_version.txt"

# bootstrap repo if needed
bootstrap_if_needed

# prepare major branch name A10 from version like 10.3
MAJOR_BRANCH="${TRACK}$(echo "${VERSION}" | cut -d. -f1)"
info "Target major branch: ${MAJOR_BRANCH}"

# safety: if parent is set, compute parent branch
if [ -n "${PARENT:-}" ]; then
  PARENT_TRACK=$(echo "${PARENT}" | sed 's/^\([A-Za-z]\).*$/\1/')
  PARENT_MAJOR=$(echo "${PARENT}" | sed 's/^[A-Za-z]//;s/\..*$//')
  PARENT_BRANCH="${PARENT_TRACK}${PARENT_MAJOR}"
  info "Parent branch resolved to ${PARENT_BRANCH}"
fi

# -------------------------
# Snapshot
# -------------------------
make_snapshot

# -------------------------
# Ensure parent exists if given
# -------------------------
if [ -n "${PARENT:-}" ]; then
  if ! git_branch_exists "${PARENT_BRANCH}"; then
    warn "Parent branch ${PARENT_BRANCH} not found locally."
    if [ "${UNSAFE_MODE}" -eq 1 ]; then
      warn "--dangerous set: proceeding without creating parent branch"
    else
      if [ "${FORCE_YES}" -eq 1 ]; then
        info "Auto-creating parent branch ${PARENT_BRANCH} from main"
        git checkout -b "${PARENT_BRANCH}" main || true
      else
        read -p "Create parent branch ${PARENT_BRANCH} from main? (y/n): " cpar
        if [[ "$cpar" =~ ^[Yy] ]]; then
          git checkout -b "${PARENT_BRANCH}" main
          git_safe_commit "bootstrap parent branch ${PARENT_BRANCH}"
        else
          warn "Proceeding without parent branch locally. Ensure remote exists when merging."
        fi
      fi
    fi
  fi
fi

# -------------------------
# Cross-track warning
# -------------------------
if [ -n "${PARENT:-}" ]; then
  if [ "${PARENT_TRACK}" != "${TRACK}" ]; then
    if [ "${UNSAFE_MODE}" -eq 1 ] || [ "${FORCE_YES}" -eq 1 ]; then
      warn "Cross-track build detected but proceeding (--dangerous or --yes set)."
    else
      read -p "Warning: cross-track build (building ${TRACK} based on ${PARENT_TRACK}). Continue? (Y/n): " crossok
      crossok=${crossok:-Y}
      if [[ ! "$crossok" =~ ^[Yy] ]]; then [ "${NO_ROLLBACK}" -eq 1 ] || rollback_snapshot; die "User aborted due to cross-track selection."; fi
    fi
  fi
fi

# -------------------------
# Checkout/create major branch
# -------------------------
git_checkout_or_create_branch "${MAJOR_BRANCH}"

# -------------------------
# If parent exists & has commits ahead -> ask to merge (unless forced)
# -------------------------
if [ -n "${PARENT_BRANCH:-}" ] && git_branch_exists "${PARENT_BRANCH}"; then
  ahead=$(git rev-list --count "${MAJOR_BRANCH}..${PARENT_BRANCH}" 2>/dev/null || echo 0)
  if [ "${ahead}" -gt 0 ]; then
    if [ "${UNSAFE_MODE}" -eq 1 ] || [ "${FORCE_YES}" -eq 1 ]; then
      info "Parent ${PARENT_BRANCH} ahead of ${MAJOR_BRANCH} - auto-merging (unsafe/yes)"
      git merge "${PARENT_BRANCH}" || { err "Merge failed"; [ "${NO_ROLLBACK}" -eq 1 ] || rollback_snapshot; exit 1; }
    else
      read -p "Parent ${PARENT_BRANCH} is ahead of ${MAJOR_BRANCH}. Merge ${PARENT_BRANCH} -> ${MAJOR_BRANCH} before build? (Y/n): " mergok
      mergok=${mergok:-Y}
      if [[ "$mergok" =~ ^[Yy] ]]; then
        info "Merging ${PARENT_BRANCH} into ${MAJOR_BRANCH}..."
        git merge "${PARENT_BRANCH}" || { err "Merge conflict. Rolling back."; [ "${NO_ROLLBACK}" -eq 1 ] || rollback_snapshot; exit 1; }
      else
        info "User declined merge. Proceeding without merging."
      fi
    fi
  fi
fi

# -------------------------
# Commit working tree (unless user disables)
# -------------------------
if [ "${NO_COMMIT}" -eq 1 ]; then
  info "--no-commit set: skipping commit"
  HASH="no-commit"
else
  if [ -z "${COMMIT_MSG:-}" ]; then
    COMMIT_MSG="Build ${VERSION_TAG}"
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    info "[dry] would git commit -m \"$COMMIT_MSG\""
    HASH="dry-run"
  else
    git_safe_commit "$COMMIT_MSG"
    HASH="$(git_get_short_hash)"
    ok "Committed, HEAD=${HASH}"
  fi
fi

# -------------------------
# Write to history
# -------------------------
DATE_NOW="$(timestamp)"
echo "${DATE_NOW} ${VERSION_TAG} commit=${HASH}" >> "${HISTORY_FILE}"
ok "Logged build to ${HISTORY_FILE}"

# -------------------------
# Run build (idf.py)
# -------------------------
if [ "${NO_FLASH}" -eq 1 ]; then
  info "--no-flash set: running idf.py build only"
  if [ "${DRY_RUN}" -eq 1 ]; then info "[dry] idf.py -p ${PORT} build"; else idf.py -p "${PORT}" build; fi
else
  info "Running: idf.py -p ${PORT} build flash monitor"
  if [ "${DRY_RUN}" -eq 1 ]; then
    info "[dry] would run: idf.py -p ${PORT} build flash monitor"
  else
    # spinner while building
    spinner_start
    set +e
    idf.py -p "${PORT}" build flash monitor
    BUILD_EXIT=$?
    set -e
    spinner_stop
    if [ "${BUILD_EXIT}" -ne 0 ]; then
      err "Build failed with exit code ${BUILD_EXIT}. Rolling back."
      [ "${NO_ROLLBACK}" -eq 1 ] || rollback_snapshot
      exit 1
    fi
  fi
fi

ok "Build completed successfully for ${VERSION_TAG}"

# -------------------------
# Tag on success
# -------------------------
TAG="v${TRACK}${VERSION}"
git_tag_build "${TAG}" "Build ${VERSION_TAG}"
ok "Tagged ${TAG}"
git_safe_commit()

# -------------------------
# Stable merge to main prompt (STABILITY == s)
# -------------------------
if [ "${STABILITY}" = "s" ]; then
  if [ "${UNSAFE_MODE}" -eq 1 ] || [ "${FORCE_YES}" -eq 1 ]; then
    info "Auto-merging ${MAJOR_BRANCH} into main (unsafe/yes)"
    make_snapshot
    git_merge_branch_into "${MAJOR_BRANCH}" "main" || { err "Merge failed. Rolling back."; [ "${NO_ROLLBACK}" -eq 1 ] || rollback_snapshot; exit 1; }
    git tag -a "${TAG}" -m "Release ${TAG}" || true
    ok "Merged ${MAJOR_BRANCH} into main and tagged ${TAG}"
  else
    read -p "Build marked stable. Merge branch ${MAJOR_BRANCH} into main? (Y/n): " domerge
    domerge=${domerge:-Y}
    if [[ "$domerge" =~ ^[Yy] ]]; then
      make_snapshot
      git_merge_branch_into "${MAJOR_BRANCH}" "main" || { err "Merge failed. Rolling back."; [ "${NO_ROLLBACK}" -eq 1 ] || rollback_snapshot; exit 1; }
      git tag -a "${TAG}" -m "Release ${TAG}" || true
      ok "Merged ${MAJOR_BRANCH} into main and tagged ${TAG}"
    else
      info "User declined merge to main."
    fi
  fi
fi

ok "Build flow complete. Version: ${VERSION_TAG}"
exit 0
