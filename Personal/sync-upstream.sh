#!/bin/zsh
# Bring this fork up to date with pauljoda/Crest.
#
#   main  = exact mirror of upstream/main (never commit here)
#   mine  = main + your personal changes (the branch you build from)
#
# Usage: Personal/sync-upstream.sh [--rebase]
#   default  merges upstream/main into mine (no force push, keeps history)
#   --rebase replays your commits on top of upstream/main (linear history,
#            needs a --force-with-lease push of mine)
set -euo pipefail

repository_root="${0:A:h:h}"
cd "$repository_root"

mode="merge"
[[ "${1:-}" == "--rebase" ]] && mode="rebase"

if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "Working tree is not clean. Commit or stash first."
  exit 1
fi

start_branch="$(git rev-parse --abbrev-ref HEAD)"

print "Fetching upstream..."
git fetch upstream --tags --prune

print "Fast-forwarding main to upstream/main..."
git checkout -q main
git merge --ff-only upstream/main
git push -q origin main

git checkout -q mine
behind="$(git rev-list --count mine..main)"
if (( behind == 0 )); then
  print "mine is already up to date with upstream."
else
  print "Bringing $behind upstream commit(s) into mine ($mode)..."
  if [[ "$mode" == "rebase" ]]; then
    git rebase main
    git push --force-with-lease origin mine
  else
    git merge --no-edit main
    git push -q origin mine
  fi
fi

git checkout -q "$start_branch"
print "Done. mine is at $(git rev-parse --short mine); upstream/main is $(git rev-parse --short upstream/main)."
print "Your personal commits on top of upstream:"
git log --oneline main..mine | sed 's/^/  /' || true
