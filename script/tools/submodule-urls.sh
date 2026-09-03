#!/usr/bin/env bash
# The Infinity forks are consumed as submodules. While choice_v2 is scaffolded locally they
# point at ../forks/*; once the forks are pushed to the org they point at GitHub. This flips
# between the two without touching the pinned commits.
#
#   ./script/tools/submodule-urls.sh org     # before pushing / in CI
#   ./script/tools/submodule-urls.sh local   # to develop against ../forks
set -euo pipefail

MODE="${1:-}"
ORG="${CHOICE_ORG:-choice-exchange}"
REPOS=(infinity-core infinity-periphery infinity-universal-router)

case "$MODE" in
  org)   for r in "${REPOS[@]}"; do git submodule set-url "lib/$r" "https://github.com/$ORG/$r.git"; done ;;
  local) for r in "${REPOS[@]}"; do git submodule set-url "lib/$r" "../forks/$r"; done ;;
  *)     echo "usage: $0 {org|local}" >&2; exit 2 ;;
esac

git submodule sync --quiet
echo "submodule urls now:"
git config -f .gitmodules --get-regexp '^submodule\..*\.url$'
echo
echo "pinned commits (unchanged):"
git ls-tree HEAD lib | awk '{print "  " $3 "  " $4}'
