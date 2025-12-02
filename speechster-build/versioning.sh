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
