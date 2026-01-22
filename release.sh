#!/usr/bin/env bash
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "git is required." >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [ ! -f VERSION ]; then
  echo "VERSION file not found in repo root." >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" = "HEAD" ]; then
  echo "Detached HEAD. Checkout a branch before releasing." >&2
  exit 1
fi

remote="origin"
if ! git remote get-url "$remote" >/dev/null 2>&1; then
  remotes="$(git remote)"
  if [ -z "$remotes" ]; then
    echo "No git remotes configured." >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$remotes" | wc -l | tr -d ' ')" -eq 1 ]; then
    remote="$remotes"
  else
    echo "Available remotes:"
    printf '%s\n' "$remotes"
    read -r -p "Remote to push to: " remote
    if [ -z "$remote" ]; then
      echo "No remote selected." >&2
      exit 1
    fi
  fi
fi

staged_changes="$(git diff --cached --name-only)"
if [ -n "$staged_changes" ] && [ "$staged_changes" != "VERSION" ]; then
  echo "Staged changes detected. Commit or unstage them before releasing." >&2
  printf '%s\n' "$staged_changes" >&2
  exit 1
fi

working_changes="$(git status --porcelain)"
if [ -n "$working_changes" ]; then
  echo "Working tree has changes:" >&2
  printf '%s\n' "$working_changes" >&2
  read -r -p "Continue with release anyway? [y/N] " continue_release
  case "$continue_release" in
    y|Y) ;;
    *) exit 1 ;;
  esac
fi

read -r -p "Release version (e.g. v0.1.0 or 0.1.0): " input_version
input_version="${input_version//[[:space:]]/}"
if [ -z "$input_version" ]; then
  echo "Version cannot be empty." >&2
  exit 1
fi

version="${input_version#v}"
tag="v$version"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists." >&2
  exit 1
fi

printf '%s\n' "$tag" > VERSION
git add VERSION
if git diff --cached --quiet; then
  echo "VERSION already set to $tag; tagging current HEAD."
else
  git commit -m "Release $tag"
fi
git tag "$tag"

if [ -x "./build-app.sh" ]; then
  read -r -p "Run ./build-app.sh now? [y/N] " build_now
  case "$build_now" in
    y|Y) ./build-app.sh ;;
    *) ;;
  esac
fi

git push "$remote" "$current_branch" --tags
echo "Pushed $tag to $remote/$current_branch"
