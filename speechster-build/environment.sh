#!/usr/bin/env bash
# environment.sh - environment helpers

get_verbose_flag() {
  echo "${SPEECHSTER_VERBOSE:-1}"
}
