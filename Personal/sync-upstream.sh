#!/bin/zsh
# Bring this fork up to date with pauljoda/Crest.
#
#   main  = exact mirror of upstream/main (never commit here)
#   mine  = main + your personal changes (the branch you build from)
#
# Usage: Personal/sync-upstream.sh [--rebase] [--no-push]
#   default   merges upstream/main into mine (no force push, keeps history)
#   --rebase  replays your commits on top of upstream/main (linear history,
#             needs a --force-with-lease push of mine)
#   --no-push updates the local branches only
#
# Run it from `mine`. A conflicting merge is aborted and reported, leaving
# the checkout as it was; resolve by merging `main` into `mine` yourself.
set -euo pipefail

repository_root="${0:A:h:h}"
cd "$repository_root"

mode="merge"
push=true
for argument in "$@"; do
  case "$argument" in
    --rebase) mode="rebase" ;;
    --no-push) push=false ;;
    *) print -u2 "Unknown option: $argument"; exit 2 ;;
  esac
done

if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "Working tree is not clean. Commit or stash first."
  exit 1
fi
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "mine" ]]; then
  print -u2 "Switch to the mine branch first (git checkout mine)."
  exit 1
fi

print "==> Fetching upstream"
git fetch upstream --tags --prune

print "==> Fast-forwarding main to upstream/main"
# main is not checked out, so fetch updates it in place; a non-fast-forward
# is refused, which is what a pristine mirror wants.
git fetch -q . upstream/main:main

behind="$(git rev-list --count mine..main)"
if (( behind == 0 )); then
  print "mine is already up to date with upstream."
else
  print "==> Bringing $behind upstream commit(s) into mine ($mode)"
  if [[ "$mode" == "rebase" ]]; then
    if ! git rebase main; then
      git rebase --abort
      print -u2 "Rebase conflicts with your personal commits. Run 'git rebase main' and resolve by hand."
      exit 3
    fi
  else
    if ! git merge --no-edit main; then
      conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
      git merge --abort
      print -u2 "Merge conflicts with your personal commits in: $conflicts"
      print -u2 "Run 'git merge main' and resolve by hand."
      exit 3
    fi
  fi
fi

if [[ "$push" == true ]]; then
  print "==> Pushing to your fork"
  git push -q origin main || print -u2 "warning: could not push main to origin (continuing)"
  if [[ "$mode" == "rebase" ]]; then
    git push -q --force-with-lease origin mine || print -u2 "warning: could not push mine to origin (continuing)"
  else
    git push -q origin mine || print -u2 "warning: could not push mine to origin (continuing)"
  fi
fi

print "Done. mine is at $(git rev-parse --short mine); upstream/main is $(git rev-parse --short upstream/main)."
print "Your personal commits on top of upstream:"
git log --oneline main..mine | sed 's/^/  /' || true
