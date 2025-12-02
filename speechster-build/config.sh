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
EOF
}