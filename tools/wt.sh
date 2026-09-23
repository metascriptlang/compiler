#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
usage: tools/wt.sh <command> [args]

  new <name> [rev]      create branch wt/<name> at rev (default main) in
                        $MSC_WT_ROOT/wt-<name>, provision vendor, paper and a
                        builder ./msc, seed the card $MSC_WT_ROOT/<name>.md;
                        prints the worktree path as the last line
  card [name|path]      print the card of a worktree (default: the current one):
                        its path, then Goal, Done when and State
  ls [--stale]          one line per worktree: branch, dirty files, unlanded
                        commits, live processes, out/ size, the card's goal or
                        NO CARD, then every card that has no wt/<name> branch;
                        --stale hides the ones a process still works in
  rm <name|path> [--force]
                        remove a worktree; refuses while it holds dirty files,
                        unlanded commits or live processes, and names them;
                        --force discards exactly what it names
  land [name] [--also '<cmd>']... [--no-gate]
                        rebase onto main, gate (tools/gate.sh picks the lanes
                        from the diff, then each --also command), then move
                        main forward and sync the main checkout path by path;
                        a main that moved during the gate only by paths no lane
                        tests is rebased onto without a second gate;
                        --no-gate lands on evidence gathered outside the gate
  hook-create           WorktreeCreate hook body (reads the hook JSON on stdin)
  hook-remove           WorktreeRemove hook body (reads the hook JSON on stdin)
  hook-session          SessionStart hook body (prints the current worktree's card
                        and the compiler inbox tally by State, then by Kind)

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

card_path() { printf '%s/%s.md\n' "$ROOT" "$(printf '%s' "$1" | tr '/' '-')"; }

card_name_of() {
  local br
  br=$(git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null) || return 1
  case "$br" in
    wt/*) printf '%s\n' "${br#wt/}" ;;
    *) return 1 ;;
  esac
}

card_goal() {
  awk '/^## /{on=($0=="## Goal"); next} on && NF{print; exit}' "$1" 2>/dev/null
}

seed_card() {
  local c
  c=$(card_path "$1")
  [ -e "$c" ] && return 0
  printf '# %s\n\nRepo: `%s` · worktree `%s` · branch `wt/%s`\nLayer:\nKind:\nMechanism:\n\n## Goal\n\n## Done when\n\n## State\n' \
    "$1" "$MAIN" "$(wt_dir "$1")" "$1" >"$c" || return 1
  say "card: $c"
}

card_is_foreign() {
  local repo
  repo=$(grep -m1 '^Repo:' "$1" 2>/dev/null) || return 1
  case "$repo" in
    *"$(basename "$MAIN")"*) return 1 ;;
    *) return 0 ;;
  esac
}

orphan_cards() {
  local c name
  for c in "$ROOT"/*.md; do
    [ -e "$c" ] || continue
    card_is_foreign "$c" && continue
    name=$(basename "$c" .md)
    git -C "$MAIN" show-ref --verify --quiet "refs/heads/wt/$name" || printf '%s\n' "$c"
  done
}

inbox_tally() {
  local dir=${MSC_INBOX:-$(dirname "$ROOT")/.inbox/compiler} n
  n=$(find "$dir" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] || return 0
  printf '%s card(s) in %s:' "$n" "$dir"
  grep -h -m1 '^State:' "$dir"/*.md 2>/dev/null \
    | awk -v n="$n" '{s=$2; sub(/[.,]$/, "", s); t[s]++; k++} END {for (s in t) printf " %d %s ·", t[s], s; if (n > k) printf " %d without a State line ·", n - k}' \
    | sed 's/ ·$//'
  printf '\n'
  inbox_kinds "$dir" "$n"
  inbox_pins "$dir" "$n"
}

inbox_pins() {
  local dir=$1 n=$2 pinned unpinned f
  pinned=$(grep -l -E '^Pinned by:[ \t]*[^ \t]' "$dir"/*.md 2>/dev/null | wc -l | tr -d ' ')
  unpinned=$(grep -l -E '^State:[ \t]*landed' "$dir"/*.md 2>/dev/null | while IFS= read -r f; do
    grep -qE '^Pinned by:[ \t]*[^ \t]' "$f" || basename "$f"
  done)
  printf 'pins: %d of %d card(s) name one' "$pinned" "$n"
  [ -z "$unpinned" ] || printf ' · fixed but unpinned, do not delete: %s' \
    "$(printf '%s\n' "$unpinned" | paste -sd, - | sed 's/,/, /g')"
  printf '\n'
}

inbox_kinds() {
  local dir=$1 n=$2 kinds new
  kinds=$(grep -h -m1 '^Kind:' "$dir"/*.md 2>/dev/null \
    | awk -v n="$n" '{sub(/^Kind:[ \t]*/, ""); sub(/[ \t]+$/, ""); if (!NF) next; t[$0]++; k++}
                     END {if (!k) exit; for (s in t) printf " %d %s ·", t[s], s; if (n > k) printf " %d unclassified ·", n - k}' \
    | sed 's/ ·$//')
  [ -n "$kinds" ] || return 0
  new=$(grep -lE '^Mechanism:.*NEW MECHANISM' "$dir"/*.md 2>/dev/null | wc -l | tr -d ' ')
  printf 'by kind:%s' "$kinds"
  [ "$new" -gt 0 ] && printf ' · %d NEW MECHANISM' "$new"
  printf '\n'
}

worktrees() { git -C "$MAIN" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | tail -n +2; }

norm_dir() { if [ -d "$1" ]; then (cd "$1" && pwd -P); else printf '%s\n' "$1"; fi; }

native_dir() { (cd "$1" && pwd -W 2>/dev/null) || printf '%s\n' "$1"; }

is_worktree() {
  local w
  while IFS= read -r w; do
    [ "$(norm_dir "$w")" = "$1" ] && return 0
  done < <(worktrees)
  return 1
}

resolve_target() {
  local t=$1 d
  case "$t" in
    /* | ?:/* | ?:\\*) d=$t ;;
    *) d=$(wt_dir "$t") ;;
  esac
  d=$(norm_dir "$d")
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
    rm -f "$w/msc" "$w/msc.exe"
    cp "$c" "$w/msc" || return 1
    if (cd "$w" && ./msc check src/index.ms >/dev/null 2>&1); then
      say "builder: $c"
      return 0
    fi
    say "builder: $c cannot check src/index.ms at this rev, skipped"
  done
  rm -f "$w/msc" "$w/msc.exe"
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
    seed_card "$name" || die "step card: cannot write $(card_path "$name")"
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
  seed_card "$name" || die "step card: cannot write $(card_path "$name")"
  printf '%s\n' "$w"
}

cmd_card() {
  local target=${1:-} w name c
  if [ -n "$target" ] && [ ! -d "$target" ] && [ -e "$(card_path "$target")" ]; then
    name=$target
  else
    if [ -n "$target" ]; then w=$(resolve_target "$target"); else w=$(git rev-parse --show-toplevel); fi
    name=$(card_name_of "$w") || die "card: $w is not on a wt/<name> branch"
  fi
  c=$(card_path "$name")
  [ -e "$c" ] || die "card: no card at $c"
  printf '%s\n' "$c"
  cat "$c"
}

hook_session() {
  local w name c
  w=$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --show-toplevel 2>/dev/null) || return 0
  if name=$(card_name_of "$w"); then
    c=$(card_path "$name")
    if [ -e "$c" ]; then
      printf 'Card of this worktree, %s:\n' "$c"
      cat "$c"
    else
      printf 'This worktree is on wt/%s and has no card at %s; write its Goal and "Done when" before the first commit.\n' "$name" "$c"
    fi
  fi
  inbox_tally
}

ls_row() {
  local i=$1 w=$2 table br dirty ahead pids out name goal=""
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
  name=$(card_name_of "$w") && goal=$(card_goal "$(card_path "$name")" | cut -c1-72)
  printf '%s\t%-7s %-5s %-5s %-6s %-40s %s  · %s\n' "$i" "$dirty" "$ahead" "$pids" "$out" "$br" "$w" "${goal:-NO CARD}"
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
  orphan_cards | sed 's/^/card without a wt\/<name> branch: /'
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
  case "$br" in
    wt/*) [ -e "$(card_path "${br#wt/}")" ] && say "card: $(card_path "${br#wt/}") stays; delete it once its \"Done when\" holds" ;;
  esac
  return 0
}

main_blob() {
  local f=$MAIN/$1
  if [ -L "$f" ]; then
    printf '%s' "$(readlink "$f")" | git hash-object --stdin
  elif [ -f "$f" ]; then
    git hash-object -- "$f"
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
  local target="" also=() w old new moved paths clash p failed=0 cmd gate=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --also) also+=("${2:?--also needs a command}"); shift ;;
      --no-gate) gate=0 ;;
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
  if [ "$gate" -eq 1 ]; then
    (cd "$w" && tools/gate.sh --base "$old") >&2 || die "land: the gate is not green"
  else
    say "land: --no-gate, tools/gate.sh did not run"
  fi
  for cmd in "${also[@]+"${also[@]}"}"; do
    say "gate: $cmd"
    (cd "$w" && bash -c "$cmd") >&2 || die "land: gate '$cmd' failed"
  done
  while :; do
    moved=$(git -C "$MAIN" rev-parse "$BASE")
    if [ "$moved" != "$old" ]; then
      (cd "$w" && tools/gate.sh --inert "$old" "$moved") || die "land: $BASE moved during the gate to $(git -C "$MAIN" rev-parse --short "$moved") with paths a lane tests; run land again"
      say "land: $BASE moved to $(git -C "$MAIN" rev-parse --short "$moved") by paths no lane tests; rebasing onto it without a second gate"
      if ! git -C "$w" rebase "$moved" >&2; then
        git -C "$w" rebase --abort >/dev/null 2>&1
        die "land: rebase onto $BASE conflicts; rebase by hand in $w"
      fi
      old=$moved
      new=$(git -C "$w" rev-parse HEAD)
    fi
    paths=$(git -C "$w" diff --name-only --no-renames "$old" "$new")
    clash=$(main_held "$old" "$paths")
    [ -z "$clash" ] || die "land: the main checkout holds uncommitted work on paths this land writes:
$(printf '%s\n' "$clash" | sed 's/^/  /')"
    git -C "$MAIN" update-ref -m "wt land $(basename "$w")" "refs/heads/$BASE" "$new" "$old" 2>/dev/null && break
  done
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
  card) shift; cmd_card "$@" ;;
  ls) shift; cmd_ls "$@" ;;
  __ls_row) ls_row "${2%%$'\t'*}" "${2#*$'\t'}" ;;
  rm) shift; cmd_rm "$@" ;;
  land) shift; cmd_land "$@" ;;
  hook-create) name=$(hook_field name); w=$(cmd_new "$name") && native_dir "$w" ;;
  hook-remove) path=$(hook_field worktree_path); cmd_rm "$path" ;;
  hook-session) hook_session ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
