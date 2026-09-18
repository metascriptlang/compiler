#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
usage: tools/wt.sh <command> [args]

  new <name> [rev]      create branch wt/<name> at rev (default main) in
                        $MSC_WT_ROOT/wt-<name>, provision vendor, paper and a
                        builder ./msc; prints the worktree path as the last line
  ls [--stale]          one line per worktree: branch, dirty files, unlanded
                        commits, live processes, out/ size; --stale hides the
                        ones a process still works in
  rm <name|path> [--force]
                        remove a worktree; refuses while it holds dirty files,
                        unlanded commits or live processes, and names them;
                        --force discards exactly what it names
  land [name] [--also '<cmd>']...
                        rebase onto main, gate (tools/gate.sh picks the lanes
                        from the diff, then each --also command), then move
                        main forward and sync the main checkout path by path
  hook-create           WorktreeCreate hook body (reads the hook JSON on stdin)
  hook-remove           WorktreeRemove hook body (reads the hook JSON on stdin)

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

resolve_target() {
  local t=$1 d
  case "$t" in
    /*) d=$t ;;
    *) d=$(wt_dir "$t") ;;
  esac
  [ -d "$d" ] && d=$(cd "$d" && pwd -P)
  is_worktree "$d" || die "no worktree at $d"
  printf '%s\n' "$d"
}

cwd_table() {
  lsof -nP -d cwd -F pn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}'
}

ancestors() {
  local p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    printf '%s\n' "$p"
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
}

procs_in() {
  local dir=$1 table=$2 skip
  skip=$(ancestors | tr '\n' ' ')
  printf '%s\n' "$table" | awk -F'\t' -v d="$dir" -v skip=" $skip" 'index(skip, " " $1 " ")==0 && ($2==d || index($2, d "/")==1){print $1}' | sort -u
}

unlanded() {
  git -C "$1" rev-list --cherry-pick --right-only --no-merges "$BASE...HEAD" 2>/dev/null
}

kib_human() {
  awk -v k="$1" 'BEGIN{ split("K M G T",u," "); i=1; while (k>=1024 && i<4) { k/=1024; i++ } printf (k<10 && i>1) ? "%.1f%s" : "%.0f%s", k, u[i] }'
}

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

ls_row() {
  local i=$1 w=$2 table br dirty ahead pids out
  table=$(cat "$WT_CWD_TABLE")
  pids=$(procs_in "$w" "$table" | wc -l | tr -d ' ')
  [ "${WT_STALE:-0}" -eq 1 ] && [ "$pids" -gt 0 ] && return
  if [ ! -d "$w" ]; then
    printf '%s\t%-7s %-5s %-5s %-6s %-40s %s\n' "$i" gone - "$pids" - - "$w"
    return
  fi
  br=$(git -C "$w" symbolic-ref -q --short HEAD || printf 'detached@%s' "$(git -C "$w" rev-parse --short HEAD 2>/dev/null)")
  dirty=$(wt_status "$w" | grep -c . | tr -d ' ')
  ahead=$(unlanded "$w" | wc -l | tr -d ' ')
  out=-
  [ -d "$w/out" ] && out=$(kib_human "$(du -sk "$w/out" 2>/dev/null | awk '{print $1}')")
  printf '%s\t%-7s %-5s %-5s %-6s %-40s %s\n' "$i" "$dirty" "$ahead" "$pids" "$out" "$br" "$w"
}

cmd_ls() {
  local table
  WT_STALE=0
  [ "${1:-}" = --stale ] && WT_STALE=1
  table=$(mktemp) || die "ls: mktemp failed"
  cwd_table >"$table"
  printf '%-7s %-5s %-5s %-6s %-40s %s\n' DIRTY AHEAD PROCS OUT BRANCH PATH
  worktrees | awk '{printf "%d\t%s%c", NR, $0, 0}' \
    | WT_CWD_TABLE=$table WT_STALE=$WT_STALE xargs -0 -P 8 -n 1 bash "$0" __ls_row \
    | sort -n | cut -f2-
  rm -f "$table"
}

wt_status() {
  local w=$1 out
  if out=$(git -C "$w" status --porcelain 2>/dev/null); then
    printf '%s' "$out"
  elif out=$(git -C "$w" diff --name-status --ignore-submodules=all HEAD 2>/dev/null && git -C "$w" ls-files --others --exclude-standard 2>/dev/null | sed 's/^/?? /'); then
    printf '%s' "$out"
  else
    printf '%s' "!! git cannot read the state of this worktree; uncommitted work cannot be ruled out"
  fi
}

live_submodules() {
  local w=$1 d
  git -C "$w" ls-files -s 2>/dev/null | awk '$1 == 160000 { print $4 }' | while IFS= read -r d; do
    [ -e "$w/$d/.git" ] && [ ! -L "$w/$d" ] && printf '%s\n' "$d"
  done
  return 0
}

cmd_rm() {
  local target="" force=0 a w table pids dirty subs ahead br cost=0 removeflag=() e
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      *) target=$a ;;
    esac
  done
  [ -n "$target" ] || die "rm: missing <name|path>"
  w=$(resolve_target "$target")
  [ "$w" != "$MAIN" ] || die "rm: refusing to remove the main checkout"
  table=$(cwd_table)
  pids=$(procs_in "$w" "$table")
  dirty=$(wt_status "$w")
  subs=$(live_submodules "$w")
  ahead=$(unlanded "$w")
  br=$(git -C "$w" symbolic-ref -q --short HEAD || true)
  if [ -n "$pids" ]; then
    cost=1; say "live processes in $w:"
    for e in $pids; do say "  $(ps -o pid=,command= -p "$e" 2>/dev/null | cut -c1-120)"; done
  fi
  if [ -n "$dirty" ]; then
    cost=1; say "uncommitted and untracked files:"; printf '%s\n' "$dirty" | sed 's/^/  /' >&2
  fi
  if [ -n "$subs" ]; then
    cost=1; say "initialized submodule checkouts (git removes them only by force):"; printf '%s\n' "$subs" | sed 's/^/  /' >&2
  fi
  if [ -n "$ahead" ]; then
    cost=1; say "commits not on $BASE${br:+ (branch $br is deleted with the worktree)}:"
    for e in $ahead; do say "  $(git -C "$w" log -1 --format='%h %s' "$e")"; done
  fi
  if [ "$cost" -eq 1 ] && [ "$force" -eq 0 ]; then
    die "rm: $w still holds the above; rerun with --force to discard exactly that"
  fi
  [ -d "$w/out" ] && say "out/: $(kib_human "$(du -sk "$w/out" | awk '{print $1}')")"
  local paper_before="" paper_after
  [ -d "$MAIN/paper" ] && paper_before=$(find "$MAIN/paper/" | wc -l | tr -d ' ')
  { [ -n "$dirty" ] || [ -n "$subs" ]; } && removeflag=(--force)
  if ! git -C "$MAIN" worktree remove "${removeflag[@]}" "$w"; then
    die "rm: git refused to remove $w for a reason not listed above; nothing else was forced"
  fi
  if [ -n "$paper_before" ]; then
    paper_after=$(find "$MAIN/paper/" | wc -l | tr -d ' ')
    [ "$paper_before" = "$paper_after" ] || die "rm: paper/ changed from $paper_before to $paper_after entries"
  fi
  case "$br" in
    wt/*) git -C "$MAIN" branch -D "$br" >/dev/null ;;
  esac
  say "removed $w"
}

main_blob() {
  local f=$MAIN/$1
  if [ -L "$f" ]; then
    printf '%s' "$(readlink "$f")" | git hash-object --stdin
  elif [ -f "$f" ]; then
    git hash-object --no-filters -- "$f"
  fi
}

main_held() {
  local old=$1 paths=$2 p was
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    was=$(git -C "$MAIN" ls-tree "$old" -- "$p")
    [ "$(printf '%s' "$was" | awk '{print $1}')" = 160000 ] && continue
    if [ "$(main_blob "$p")" != "$(printf '%s' "$was" | awk '{print $3}')" ]; then
      printf '%s\n' "$p"
    elif [ -n "$(git -C "$MAIN" diff --cached --name-only "$old" -- "$p")" ]; then
      printf '%s (staged)\n' "$p"
    fi
  done <<<"$paths"
}

main_index() {
  local try
  for try in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$MAIN/.git/index.lock" ] && { sleep 1; continue; }
    git -C "$MAIN" update-index "$@" && return 0
    sleep 1
  done
  say "land: the main checkout index stayed locked; could not record $*"
  return 1
}

sync_main_path() {
  local p=$1 old=$2 new=$3 entry mode blob cur was
  was=$(git -C "$MAIN" ls-tree "$old" -- "$p")
  entry=$(git -C "$MAIN" ls-tree "$new" -- "$p")
  mode=$(printf '%s' "$entry" | awk '{print $1}')
  blob=$(printf '%s' "$entry" | awk '{print $3}')
  if [ "$mode" = 160000 ] || [ "$(printf '%s' "$was" | awk '{print $1}')" = 160000 ]; then
    if [ -n "$entry" ]; then main_index --add --cacheinfo "$mode,$blob,$p"; else main_index --force-remove -- "$p"; fi
    return
  fi
  cur=$(main_blob "$p")
  [ "$cur" = "$(printf '%s' "$was" | awk '{print $3}')" ] || { say "  $p: changed in the main checkout during land, left for a manual merge"; return 1; }
  if [ -z "$entry" ]; then
    main_index --force-remove -- "$p" && rm -f "$MAIN/$p"
    return
  fi
  mkdir -p "$(dirname "$MAIN/$p")"
  if [ "$mode" = 120000 ]; then
    rm -f "$MAIN/$p" && ln -s "$(git -C "$MAIN" cat-file blob "$blob")" "$MAIN/$p" || return 1
    main_index --add --cacheinfo "$mode,$blob,$p"
    return
  fi
  git -C "$MAIN" cat-file blob "$blob" >"$MAIN/$p.wt-land" && mv "$MAIN/$p.wt-land" "$MAIN/$p" || return 1
  case "$mode" in
    100755) chmod 755 "$MAIN/$p" ;;
    *) chmod 644 "$MAIN/$p" ;;
  esac
  main_index --add --cacheinfo "$mode,$blob,$p"
}

cmd_land() {
  local target="" also=() w old new paths clash p failed=0 cmd
  while [ $# -gt 0 ]; do
    case "$1" in
      --also) also+=("${2:?--also needs a command}"); shift ;;
      *) target=$1 ;;
    esac
    shift
  done
  if [ -n "$target" ]; then w=$(resolve_target "$target"); else w=$(git rev-parse --show-toplevel); fi
  [ "$w" != "$MAIN" ] || die "land: run from a worktree, not the main checkout"
  [ "$(git -C "$MAIN" symbolic-ref -q HEAD)" = "refs/heads/$BASE" ] || die "land: the main checkout is not on $BASE"
  [ -z "$(git -C "$w" status --porcelain --untracked-files=no)" ] || die "land: $w has uncommitted changes to tracked files"
  old=$(git -C "$MAIN" rev-parse "$BASE")
  if ! git -C "$w" rebase "$old" >&2; then
    git -C "$w" rebase --abort >/dev/null 2>&1
    die "land: rebase onto $BASE conflicts; rebase by hand in $w"
  fi
  new=$(git -C "$w" rev-parse HEAD)
  [ "$new" != "$old" ] || die "land: nothing to land"
  git -C "$w" merge-base --is-ancestor "$old" "$new" || die "land: HEAD does not descend from $BASE"
  (cd "$w" && tools/gate.sh --base "$old") >&2 || die "land: the gate is not green"
  for cmd in "${also[@]+"${also[@]}"}"; do
    say "gate: $cmd"
    (cd "$w" && bash -c "$cmd") >&2 || die "land: gate '$cmd' failed"
  done
  paths=$(git -C "$w" diff --name-only --no-renames "$old" "$new")
  clash=$(main_held "$old" "$paths")
  [ -z "$clash" ] || die "land: the main checkout holds uncommitted work on paths this land writes:
$(printf '%s\n' "$clash" | sed 's/^/  /')"
  git -C "$MAIN" update-ref -m "wt land $(basename "$w")" "refs/heads/$BASE" "$new" "$old" || die "land: $BASE moved during the gate; run land again"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    sync_main_path "$p" "$old" "$new" || failed=1
  done <<<"$paths"
  [ "$failed" -eq 0 ] || die "land: $BASE is at $(git -C "$MAIN" rev-parse --short "$new"); the paths above need a manual merge"
  say "landed $(git -C "$MAIN" rev-list --count "$old..$new") commit(s): $BASE $(git -C "$MAIN" rev-parse --short "$old")..$(git -C "$MAIN" rev-parse --short "$new")"
}

hook_field() {
  jq -r --arg k "$1" '.[$k] // empty'
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  ls) shift; cmd_ls "$@" ;;
  __ls_row) ls_row "${2%%$'\t'*}" "${2#*$'\t'}" ;;
  rm) shift; cmd_rm "$@" ;;
  land) shift; cmd_land "$@" ;;
  hook-create) name=$(hook_field name); cmd_new "$name" ;;
  hook-remove) path=$(hook_field worktree_path); cmd_rm "$path" ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
