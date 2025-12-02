#!/usr/bin/env bash
# esp-build.sh - Speechster Build System V3 (entrypoint)
# Place at firmware repo root. It bootstraps and executes the modular engine.
# Verbose by default; use --quiet to disable.
set -euo pipefail

# -------------------------
# ARG / ENV handling
# -------------------------
VERBOSE=1
QUIET_FLAG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet|-q) VERBOSE=0; QUIET_FLAG=1; shift ;;
    --help|-h) echo "Usage: $0 [--quiet]"; exit 0 ;;
    *) shift ;;
  esac
done
export SPEECHSTER_VERBOSE=${SPEECHSTER_VERBOSE:-$VERBOSE}

# -------------------------
# paths
# -------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="${ROOT_DIR}/speechster-build"
HISTORY_FILE="${ROOT_DIR}/build_history.txt"
CONFIG_FILE="${ROOT_DIR}/.speechster.conf"

# -------------------------
# ensure bash
# -------------------------
if [ -z "${BASH_VERSION-}" ]; then
  echo "Please use bash to run this script."
  exit 1
fi

# -------------------------
# BOOTSTRAP: create engine files if missing
# -------------------------
bootstrap_engine() {
  if [ ! -d "$ENGINE_DIR" ]; then
    echo "[bootstrap] engine not found, creating structure..."
    mkdir -p "$ENGINE_DIR"
    # create placeholder files from here (they will get overwritten by the following file dumps)
  fi

  # If module files are missing, write them.
  # We assume the caller has copied the modules below into speechster-build/.
  # If they don't exist, try to write them from here using heredocs.
  local missing=0
  for f in core.sh git-manager.sh versioning.sh logging.sh colors.sh config.sh environment.sh fail-safe.sh; do
    if [ ! -f "${ENGINE_DIR}/${f}" ]; then
      missing=1
    fi
  done

  if [ "$missing" -eq 1 ]; then
    echo "[bootstrap] Missing modules detected. Auto-creating modules..."
    # write modules here (the rest of the files will be created by this script when copying)
    cat > "${ENGINE_DIR}/colors.sh" <<'EOF'
#!/usr/bin/env bash
# colors.sh - ANSI color helpers
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

ok() { if [ "${SPEECHSTER_VERBOSE:-1}" -eq 1 ]; then echo -e "${GREEN}[OK]${RESET} $*"; else echo "[OK] $*"; fi }
info() { if [ "${SPEECHSTER_VERBOSE:-1}" -eq 1 ]; then echo -e "${CYAN}[INFO]${RESET} $*"; else echo "[INFO] $*"; fi }
warn() { if [ "${SPEECHSTER_VERBOSE:-1}" -eq 1 ]; then echo -e "${YELLOW}[WARN]${RESET} $*"; else echo "[WARN] $*"; fi }
err()  { if [ "${SPEECHSTER_VERBOSE:-1}" -eq 1 ]; then echo -e "${RED}[ERR]${RESET} $*"; else echo "[ERR] $*"; fi }
EOF

    cat > "${ENGINE_DIR}/logging.sh" <<'EOF'
#!/usr/bin/env bash
# logging.sh - verbose logging utilities

log_debug() {
  if [ "${SPEECHSTER_VERBOSE:-1}" -eq 1 ]; then
    local t=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[DEBUG] ${t} $*"
  fi
}

log_info() {
  local t=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "[INFO] ${t} $*"
}

log_warn() {
  local t=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "[WARN] ${t} $*"
}

log_error() {
  local t=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "[ERROR] ${t} $*"
}
EOF

    cat > "${ENGINE_DIR}/config.sh" <<'EOF'
#!/usr/bin/env bash
# config.sh - loads/saves .speechster.conf defaults

load_config() {
  # default values
  DEFAULT_ENV="${DEFAULT_ENV:-F}"
  DEFAULT_PORT="${DEFAULT_PORT:-/dev/ttyACM0}"
  DEFAULT_TRACK="${DEFAULT_TRACK:-A}"
  HISTORY_FILE="${HISTORY_FILE:-build_history.txt}"
  SERIES_STRATEGY="${SERIES_STRATEGY:-major}"
  if [ -f ".speechster.conf" ]; then
    # shell-safe sourcing
    source .speechster.conf
  fi
}
save_default_config() {
  cat > .speechster.conf <<EOF
# speechster default config (auto-generated)
DEFAULT_ENV="${DEFAULT_ENV}"
DEFAULT_PORT="${DEFAULT_PORT}"
DEFAULT_TRACK="${DEFAULT_TRACK}"
SERIES_STRATEGY="${SERIES_STRATEGY}"
}
EOF

    cat > "${ENGINE_DIR}/environment.sh" <<'EOF'
#!/usr/bin/env bash
# environment.sh - environment helpers

get_verbose_flag() {
  echo "${SPEECHSTER_VERBOSE:-1}"
}
EOF

    cat > "${ENGINE_DIR}/fail-safe.sh" <<'EOF'
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
EOF

    cat > "${ENGINE_DIR}/versioning.sh" <<'EOF'
#!/usr/bin/env bash
# versioning.sh - helpers for version parsing, suggestion, and validation

# validate version format major.minor
is_valid_version() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

suggest_next_version() {
  local last="$1"
  if [ -z "$last" ]; then
    echo "1.0"
    return
  fi
  # remove leading track char if present
  last="${last#[A-Za-z]}"
  if ! is_valid_version "$last"; then
    echo "1.0"
    return
  fi
  IFS='.' read -r major minor <<< "$last"
  minor=${minor:-0}
  minor=$((minor + 1))
  echo "${major}.${minor}"
}

make_version_tag() {
  local track="$1"
  local version="$2"
  local environment="$3"
  local stability="$4"
  local changetype="$5"
  local parent="$6"
  if [ -z "${parent}" ]; then
    echo "${track}${version}[${environment}|${stability}|${changetype}]"
  else
    echo "${track}${version}[${environment}|${stability}|${changetype}]::⟪${parent}⟫"
  fi
}
EOF

    cat > "${ENGINE_DIR}/git-manager.sh" <<'EOF'
#!/usr/bin/env bash
# git-manager.sh - branch and git operations

# Checks if branch exists locally
git_branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
  return $?
}

# Create and checkout branch
git_checkout_or_create_branch() {
  local branch="$1"
  if git_branch_exists "$branch"; then
    log_debug "[git] checkout $branch"
    git checkout "$branch"
  else
    log_debug "[git] create branch $branch from main"
    git checkout -b "$branch" main
  fi
}

# Create tag
git_tag_build() {
  local tag="$1"
  local message="$2"
  git tag -a "$tag" -m "$message" || true
}

# Safe commit wrapper
git_safe_commit() {
  local msg="$1"
  git add -A
  git commit -m "$msg" || true
}

# Merge helper
git_merge_branch_into() {
  local src="$1"
  local dst="$2"
  git checkout "$dst"
  git merge --ff-only "$src" 2>/dev/null || git merge "$src"
}

# show current branch and head
git_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-branch"
}
EOF

    cat > "${ENGINE_DIR}/core.sh" <<'EOF'
#!/usr/bin/env bash
# core.sh - orchestrator

# load helpers
source "${ENGINE_DIR}/colors.sh"
source "${ENGINE_DIR}/logging.sh"
source "${ENGINE_DIR}/config.sh"
source "${ENGINE_DIR}/environment.sh"
source "${ENGINE_DIR}/fail-safe.sh"
source "${ENGINE_DIR}/versioning.sh"
source "${ENGINE_DIR}/git-manager.sh"

load_config

# ensure git initialized if requested
ensure_git_initialized() {
  if [ ! -d .git ]; then
    log_info "No git repo found. Initializing..."
    git init
    git add .
    git remote add origin https://github.com/SpeechsterInnovations/Speechster-Firmware.git
    git commit -m "Init Commit" || true
    git branch -M main || true
  fi
  # ensure main exists
  if ! git show-ref --verify --quiet refs/heads/main; then
    git checkout -b main || true
  fi
}

# append history
append_history() {
  local entry="$1"
  echo "$entry" >> "${HISTORY_FILE}"
}

# parse last history parent
get_last_parent() {
  if [ -f "${HISTORY_FILE}" ]; then
    tail -n 1 "${HISTORY_FILE}" | awk '{print $2,$3,$4,$5;}' | awk '{print $2}' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# main flow
run_build_flow() {
  # interactive prompts
  local suggested=""
  if [ -f "${HISTORY_FILE}" ]; then
    lastline=$(tail -n1 "${HISTORY_FILE}")
    suggested=$(echo "${lastline}" | awk '{print $2}' | sed 's/^[A-Za-z]//' ) 2>/dev/null || true
  fi

  read -p "Track (A/B/R) [${DEFAULT_TRACK}]: " TRACK
  TRACK=${TRACK:-$DEFAULT_TRACK}
  if [ -n "${suggested}" ]; then
    next_ver=$(suggest_next_version "${suggested}")
    read -p "Version (e.g. ${next_ver}): " VERSION
    VERSION=${VERSION:-$next_ver}
  else
    read -p "Version (e.g. 1.0): " VERSION
  fi

  read -p "Environment (F/W/B/T/M) [${DEFAULT_ENV}]: " ENVIRONMENT
  ENVIRONMENT=${ENVIRONMENT:-$DEFAULT_ENV}
  read -p "Stability (s/t/e/p/d/x) [t]: " STABILITY
  STABILITY=${STABILITY:-t}
  read -p "Change Type (+/*/%/!/~/=/?): " CHANGETYPE
  read -p "Parent (leave empty if none): " PARENT

  # validate basics
  if ! is_valid_version "${VERSION}"; then
    log_error "Invalid version format. Expected major.minor (e.g. 10.3)."
    exit 1
  fi

  VERSION_TAG=$(make_version_tag "${TRACK}" "${VERSION}" "${ENVIRONMENT}" "${STABILITY}" "${CHANGETYPE}" "${PARENT}")

  log_info "Generated version tag: ${VERSION_TAG}"
  echo "${VERSION_TAG}" > build_version.txt

  # pre-flight git init/bootstrapping
  ensure_git_initialized

  # branch handling (major-branch strategy)
  MAJOR_BRANCH="${TRACK}$(echo "${VERSION}" | cut -d. -f1)"
  log_debug "Major branch: ${MAJOR_BRANCH}"

  fs_snapshot

  # ensure parent branch exists (if given)
  if [ -n "${PARENT}" ]; then
    PARENT_MAJOR=$(echo "${PARENT}" | sed 's/^[A-Za-z]//;s/\..*$//')
    PARENT_TRACK=$(echo "${PARENT}" | sed 's/\([A-Za-z]\).*/\1/')
    PARENT_BRANCH="${PARENT_TRACK}${PARENT_MAJOR}"
    if ! git_branch_exists "${PARENT_BRANCH}"; then
      log_warn "Parent branch ${PARENT_BRANCH} not found locally."
      read -p "Create parent branch ${PARENT_BRANCH} from main? (y/n): " cpar
      if [[ "${cpar}" =~ ^[Yy]$ ]]; then
        git checkout -b "${PARENT_BRANCH}" main
        git_safe_commit "bootstrap parent branch ${PARENT_BRANCH}"
      else
        log_warn "Proceeding without creating parent branch. Be sure parent exists remotely."
      fi
    fi
  fi

  # cross-track warning
  if [ -n "${PARENT}" ]; then
    PARENT_TRACK_ONLY=$(echo "${PARENT}" | sed 's/[^A-Za-z].*//')
    if [ "${PARENT_TRACK_ONLY}" != "${TRACK}" ]; then
      read -p "Warning: cross-track build (building ${TRACK} based on ${PARENT_TRACK_ONLY}). Continue? (Y/n): " crossok
      if [[ ! "${crossok}" =~ ^[Yy]$ ]]; then
        log_info "User aborted due to cross-track selection."
        fs_rollback
        exit 1
      fi
    fi
  fi

  # checkout or create major branch
  git_checkout_or_create_branch "${MAJOR_BRANCH}"

  # if parent exists and is newer -> ask to merge
  if [ -n "${PARENT}" ] && git_branch_exists "${PARENT_BRANCH}"; then
    # check if parent has commits ahead of current branch
    ahead=$(git rev-list --count "${MAJOR_BRANCH}..${PARENT_BRANCH}" 2>/dev/null || echo 0)
    if [ "${ahead}" -gt 0 ]; then
      read -p "Parent branch ${PARENT_BRANCH} is ahead of ${MAJOR_BRANCH}. Merge ${PARENT_BRANCH} -> ${MAJOR_BRANCH} before build? (Y/n): " mergok
      if [[ "${mergok}" =~ ^[Yy]$ ]]; then
        log_info "Merging ${PARENT_BRANCH} into ${MAJOR_BRANCH}..."
        git merge "${PARENT_BRANCH}" || { log_error "Merge conflict. Rolling back."; fs_rollback; exit 1; }
      else
        log_info "User declined merge. Proceeding without merging."
      fi
    fi
  fi

  # commit pending changes (optional)
  read -p "Commit working tree before build? (y/n) [y]: " DO_COMMIT
  DO_COMMIT=${DO_COMMIT:-y}
  if [[ "${DO_COMMIT}" =~ ^[Yy] ]]; then
    read -p "Commit message (empty = auto): " CM
    if [ -z "${CM}" ]; then
      CM="Build ${VERSION_TAG}"
    fi
    git_safe_commit "${CM}"
    HASH=$(git rev-parse --short HEAD || echo "no-hash")
  else
    HASH="no-commit"
  fi

  # write to history
  DATE_NOW=$(date "+%Y-%m-%d %H:%M")
  echo "${DATE_NOW} ${VERSION_TAG} commit=${HASH}" >> "${HISTORY_FILE}"

  # run the IDF build
  echo "[build] Running: idf.py -p ${DEFAULT_PORT} build flash monitor"
  idf.py -p "${DEFAULT_PORT}" build flash monitor
  BUILD_EXIT=$?
  if [ ${BUILD_EXIT} -ne 0 ]; then
    log_error "Build failed. Rolling back."
    fs_rollback
    exit 1
  fi

  log_info "Build succeeded for ${VERSION_TAG}"

  # tag on success
  TAG="v${TRACK}${VERSION}"
  git_tag_build "${TAG}" "Build ${VERSION_TAG}"
  log_info "Tagged ${TAG}"

  # stable merge to main prompt
  if [ "${STABILITY}" = "s" ]; then
    read -p "Build marked stable. Merge branch ${MAJOR_BRANCH} into main? (Y/n): " domerge
    if [[ "${domerge}" =~ ^[Yy]$ ]]; then
      fs_snapshot
      git_merge_branch_into "${MAJOR_BRANCH}" "main" || { log_error "Merge failed. Rolling back."; fs_rollback; exit 1; }
      git tag -a "${TAG}" -m "Release ${TAG}"
      log_info "Merged ${MAJOR_BRANCH} -> main and tagged ${TAG}"
    else
      log_info "User declined merge to main."
    fi
  fi

  log_info "Build flow complete."
}

# if engine invoked directly, run
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  run_build_flow
fi
EOF

    cat > "${ENGINE_DIR}/README.txt" <<'EOF'
Speechster build engine modules - auto-created during bootstrap.
Modules:
 - core.sh
 - git-manager.sh
 - versioning.sh
 - logging.sh
 - colors.sh
 - config.sh
 - environment.sh
 - fail-safe.sh
EOF

    chmod +x "${ENGINE_DIR}"/*.sh
    echo "Modules created"
  else
    echo "All modules present"
  fi
}

# -------------------------
# Load modules (they will exist after bootstrap)
# -------------------------
bootstrap_engine

# source engine modules
source "${ENGINE_DIR}/colors.sh"
source "${ENGINE_DIR}/logging.sh"
source "${ENGINE_DIR}/config.sh"
source "${ENGINE_DIR}/environment.sh"
source "${ENGINE_DIR}/fail-safe.sh"
source "${ENGINE_DIR}/versioning.sh"
source "${ENGINE_DIR}/git-manager.sh"
source "${ENGINE_DIR}/core.sh"

# ensure defaults saved
if [ ! -f "${CONFIG_FILE}" ]; then
  DEFAULT_ENV="${DEFAULT_ENV:-F}"
  DEFAULT_PORT="${DEFAULT_PORT:-/dev/ttyACM0}"
  DEFAULT_TRACK="${DEFAULT_TRACK:-A}"
  SERIES_STRATEGY="${SERIES_STRATEGY:-major}"
  save_default_config
  info "Default config created at .speechster.conf"
fi

# run the orchestrator
run_build_flow

