#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
usage: tools/wt.sh <command> [args]

  new <name> [rev]      create branch wt/<name> at rev (default main) in
                        $MSC_WT_ROOT/wt-<name>, provision vendor, paper and a
                        builder ./msc; prints the worktree path as the last line
  hook-create           WorktreeCreate hook body (reads the hook JSON on stdin)

env: MSC_WT_ROOT (default $HOME/metascript/.wt), MSC_BUILDER (tried first)
USAGE
}

say() { printf '%s\n' "$*" >&2; }
die() { say "wt: $*"; exit 1; }

MAIN=$(git worktree list --porcelain 2>/dev/null | awk 'NR==1 && /^worktree /{print substr($0,10); exit}')
[ -n "$MAIN" ] || die "not inside a git repository"
ROOT=${MSC_WT_ROOT:-$HOME/metascript/.wt}
BASE=main

wt_dir() { printf '%s/%s\n' "$ROOT" "$(printf 'wt/%s' "$1" | tr '/' '-')"; }

worktrees() { git -C "$MAIN" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | tail -n +2; }

is_worktree() { worktrees | grep -Fxq "$1"; }

provision_vendor() {
  local w=$1 d e b
  for d in $(git -C "$w" ls-files -s -- vendor | awk '$1=="160000"{print $4}'); do
    [ -d "$MAIN/$d" ] || return 1
    rm -rf "${w:?}/$d" && mkdir -p "$w/$d" || return 1
    for e in "$MAIN/$d"/* "$MAIN/$d"/.[!.]*; do
      [ -e "$e" ] || continue
      b=$(basename "$e")
      [ "$b" = .git ] && continue
      ln -s "$e" "$w/$d/$b" || return 1
    done
  done
  [ -e "$w/vendor/mbedtls/tf-psa-crypto" ]
}

pick_builder() {
  local w=$1 c
  for c in ${MSC_BUILDER:-} "$MAIN/msc" "$(command -v msc 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    cp "$c" "$w/msc" || return 1
    if (cd "$w" && ./msc check src/index.ms >/dev/null 2>&1); then
      say "builder: $c"
      return 0
    fi
    say "builder: $c cannot check src/index.ms at this rev, skipped"
  done
  rm -f "$w/msc"
  return 1
}

cmd_new() {
  local name=${1:-} rev=${2:-$BASE} w branch dirty
  [ -n "$name" ] || die "new: missing <name>"
  branch="wt/$name"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "new: '$name' is not a valid branch name"
  w=$(wt_dir "$name")
  if [ -e "$w" ]; then
    is_worktree "$(cd "$w" && pwd -P)" || die "new: $w exists and is not a worktree of $MAIN"
    say "reusing $w"
    printf '%s\n' "$w"
    return 0
  fi
  mkdir -p "$ROOT" || die "new: cannot create $ROOT"
  if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$MAIN" worktree add "$w" "$branch" >&2 || die "step worktree: git worktree add $w $branch failed"
  else
    git -C "$MAIN" worktree add -b "$branch" "$w" "$rev" >&2 || die "step worktree: git worktree add -b $branch $w $rev failed"
  fi
  provision_vendor "$w" || die "step vendor: vendor/mbedtls/tf-psa-crypto missing in $w"
  if [ -d "$MAIN/paper" ]; then
    ln -s "$MAIN/paper" "$w/paper" || die "step paper: cannot link $w/paper"
  fi
  pick_builder "$w" || die "step builder: no candidate can check src/index.ms (set MSC_BUILDER)"
  dirty=$(git -C "$w" status --porcelain)
  [ -z "$dirty" ] || die "step status: fresh worktree is not clean:
$dirty"
  printf '%s\n' "$w"
}

hook_field() {
  jq -r --arg k "$1" '.[$k] // empty'
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  hook-create) name=$(hook_field name); cmd_new "$name" ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
