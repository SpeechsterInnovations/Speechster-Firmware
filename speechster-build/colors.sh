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
