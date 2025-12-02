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
