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

  # set origin
  echo "Set Origin to: ${TRACK}${VERSION}"
  git push --set-upstream origin ${TRACK}${VERSION}

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
