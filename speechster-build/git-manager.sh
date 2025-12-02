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
