#!/usr/bin/env bash
# Every copy of a fork, at ANY depth, must be the commit `meta.forkPins` names.
#
#   script/tools/check-fork-pins.sh
#
# ## Why this exists, and why the obvious weaker check is not enough
#
# `deployments/*.json` carries three fork pins, and CI already checks them against THIS
# repo's own submodules. That is not sufficient, because **each fork carries its own copies
# of the others**, and a build resolves the copy belonging to the repo it is run from:
#
#   contracts/remappings.txt                  infinity-periphery/ -> contracts/lib/infinity-periphery
#   infinity-universal-router/remappings.txt  infinity-periphery/ -> ITS OWN lib/infinity-periphery
#                                             infinity-core/      -> that periphery's lib/infinity-core
#
# 🔴 The UniversalRouter is the only contract in this deployment built from a fork rather
# than from `contracts` - its deploy script lives in that repo - so it compiles
# `CLRouterBase` from a copy this repo's pins say nothing about. On 2026-09-07 that copy was
# `481650d`, dated 2025-02-05: 19 months stale, predating upstream's Hexens audit response.
# A testnet redeploy taken expressly to pick up the exact-output partial-fill fix came out
# BYTE-IDENTICAL to the buggy router it replaced, and the salt was burnt. This check is what
# would have caught it before the transaction, and it is PROVEN to: replaying that exact
# state - router pinned at 7e80d51 with the book agreeing, so only the nested copies are
# wrong - it reports both the stale periphery and the stale core.
#
# ## The invariant, stated precisely
#
# ALL COPIES OF A FORK AGREE WITH EACH OTHER. That is deliberately NOT "every pin is at its
# fork's HEAD": a fork's HEAD moves for CI and docs commits that change no Solidity, and
# chasing it would turn each of those into a cascade through three repos for nothing. What
# must never happen is two copies of one fork disagreeing, because then which one you get
# depends on where you happened to run the build.
#
# ⚠️ This is a DIFFERENT question from `upstream-guard`, which compares a fork's own `src/`
# against that fork's own base commit. That is the right question, it stays green straight
# through the failure above, and nothing was asking this one.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

FORKS="infinity-core infinity-periphery infinity-universal-router"
fail=0
err() { echo "::error::$*"; echo "  ERROR: $*" >&2; fail=1; }

shopt -s nullglob
books=(deployments/injective_*.json)
[ ${#books[@]} -gt 0 ] || { err "no deployments/injective_*.json to check"; exit 1; }

# --- 1. the books must agree with each other -------------------------------------------
#
# A per-network fork pin would mean per-network bytecode for the same contract, which is not
# what any of these three are for - and it would make "the pin" ambiguous everywhere below.
declare -A want
for fork in $FORKS; do
  vals="$(jq -r --arg k "$fork" '.meta.forkPins[$k] // "MISSING"' "${books[@]}" | sort -u)"
  if [ "$(printf '%s\n' "$vals" | wc -l)" -ne 1 ]; then
    err "the books disagree on meta.forkPins.$fork: $(printf '%s ' $vals)"; continue
  fi
  [ "$vals" != "MISSING" ] || { err "meta.forkPins.$fork is missing from a book"; continue; }
  [[ "$vals" =~ ^[0-9a-f]{40}$ ]] || { err "meta.forkPins.$fork is not a 40-hex sha: $vals"; continue; }
  want[$fork]="$vals"
done
[ "$fail" -eq 0 ] || exit 1

# --- 2. every gitlink, at every depth --------------------------------------------------
#
# Read from the COMMITTED TREE (`git ls-tree`), never from `git submodule status`, which
# reports whatever happens to be checked out. What a colleague gets when they clone is the
# tree, and the tree is what has to be right.
declare -A found
walk() { # <repo dir> <tree-ish> <path prefix> <depth>
  local dir="$1" ref="$2" prefix="$3" depth="$4"
  [ "$depth" -le 6 ] || return 0
  local mode type sha path full base mark
  while read -r mode type sha path; do
    [ "$mode" = "160000" ] || continue
    full="${prefix}${path}"
    base="$(basename "$path")"

    case " $FORKS " in *" $base "*)
      mark="ok"
      if [ "$sha" != "${want[$base]}" ]; then
        err "$full is ${sha:0:9} but meta.forkPins.$base is ${want[$base]:0:9}"
        mark="STALE"
      fi
      found[$base]="${found[$base]:-}${full}|${sha:0:9}|${mark} "
      ;;
    esac

    # Descend. A fork we cannot descend into is a failure rather than a skip: a check that
    # silently passes over what it cannot see is worse than no check, because it reads green.
    if [ -e "$dir/$path/.git" ]; then
      walk "$dir/$path" "$sha" "$full/" $((depth + 1))
    else
      case " $FORKS " in *" $base "*)
        err "$full is not initialised, so its own nested pins cannot be checked - run: git submodule update --init --recursive"
        ;;
      esac
    fi
  done < <(git -C "$dir" ls-tree -r "$ref" 2>/dev/null)
}
walk . HEAD "" 0

# --- 3. report -------------------------------------------------------------------------
for fork in $FORKS; do
  copies="${found[$fork]:-}"
  n=$(printf '%s' "$copies" | wc -w)
  if [ "$n" -eq 0 ]; then
    err "no submodule named $fork exists at any depth, but meta.forkPins names one"; continue
  fi
  printf '  %-26s %s  (%d cop%s)\n' "$fork" "${want[$fork]:0:9}" "$n" "$([ "$n" = 1 ] && echo y || echo ies)"
  for c in $copies; do
    IFS='|' read -r p s m <<< "$c"
    [ "$m" = "ok" ] && printf '      %s\n' "$p" || printf '      %s   <- %s %s\n' "$p" "$s" "$m"
  done
done

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'WHY'

  Two copies of one fork disagree. Whichever build runs from the repo holding the stale copy
  compiles against it - silently, and with no bytecode difference to notice until something
  is deployed. Fix by moving the STALE copy to the pin above, in the repo that owns it, then
  bumping this repo's submodule to follow. See CHOICE_V2_MAINNET_OPS.md §4a.
WHY
fi
exit $fail
