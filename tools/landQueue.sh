#!/usr/bin/env bash
set -u
Q=${MSC_LAND_QUEUE:-$HOME/metascript/.wt/queue}
WT_TOOL=${MSC_WT_TOOL:-$HOME/nerdtools/claude/tools/wt.sh}
IDLE=${MSC_LAND_QUEUE_IDLE:-600}
POLL=${MSC_LAND_QUEUE_POLL:-20}
TRIES=${MSC_LAND_QUEUE_TRIES:-3}
LOCK=$Q/runner.lock
mkdir -p "$Q"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$Q/runner.log"; }

claim() {
  local p
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' $$ >"$LOCK/pid"
    return 0
  fi
  p=$(cat "$LOCK/pid" 2>/dev/null)
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null && return 1
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$p" ] || return 1
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || return 1
  printf '%s\n' $$ >"$LOCK/pid"
  log "took over a stale lock from pid $p"
}

owns() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ]; }

release() { owns && rm -rf "$LOCK"; }

next_item() { ls "$Q"/*.item 2>/dev/null | sort | head -1; }

field() { sed -n "s/^$1=//p" "$2" | head -1; }

recover_stranded() {
  local run name
  for run in "$Q"/*.run; do
    [ -e "$run" ] || continue
    name=$(field name "$run")
    if [ -n "$name" ] && grep -qx "name=$name" "$Q"/*.item 2>/dev/null; then
      log "$name: dropped the run a dead runner left, it is queued again"
      rm -f "$run"
    else
      log "${name:-?}: queued again, a dead runner left it running"
      mv "$run" "${run%.run}.item"
    fi
  done
}

finish() {
  local name=$1 verdict=$2 text=$3
  rm -f "$Q/$name.done" "$Q/$name.red"
  printf '%s\n' "$text" >"$Q/$name.$verdict.tmp"
  mv "$Q/$name.$verdict.tmp" "$Q/$name.$verdict"
}

run_item() {
  local item=$1 name worktree tries running rc
  name=$(field name "$item")
  worktree=$(field worktree "$item")
  tries=$(field tries "$item")
  tries=$((${tries:-0} + 1))
  running="${item%.item}.run"
  mv "$item" "$running" || return
  if [ -z "$name" ] || [ ! -d "$worktree" ]; then
    log "${name:-?}: worktree ${worktree:-?} is gone"
    [ -n "$name" ] && finish "$name" red "land-queue: worktree ${worktree:-?} is gone"
    rm -f "$running"
    return
  fi
  if [ -n "$(git -C "$worktree" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    log "$name: worktree has uncommitted changes"
    finish "$name" red "land-queue: $worktree has uncommitted changes to tracked files; commit them and queue again"
    rm -f "$running"
    return
  fi
  log "$name: land, try $tries"
  printf '\n===== %s try %s\n' "$(date '+%F %T')" "$tries" >>"$Q/$name.land.log"
  (WT_CWD="$worktree" bash "$WT_TOOL" land "$worktree" >>"$Q/$name.land.log" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    log "$name: $(tail -1 "$Q/$name.land.log")"
    finish "$name" done "$(tail -1 "$Q/$name.land.log")"
    rm -f "$running"
    return
  fi
  if grep -qE 'moved during the gate to .* run land again|gate: BUSY load' <(sed -n '/===== .* try '"$tries"'$/,$p' "$Q/$name.land.log") && [ "$tries" -lt "$TRIES" ]; then
    log "$name: retry ($(tail -1 "$Q/$name.land.log"))"
    { printf 'name=%s\nworktree=%s\ntries=%s\n' "$name" "$worktree" "$tries"; } >"$running.tmp"
    mv "$running.tmp" "$item"
    rm -f "$running"
    return
  fi
  log "$name: land RED rc=$rc, main untouched — see queue/$name.red"
  finish "$name" red "$(tail -8 "$Q/$name.land.log")"
  rm -f "$running"
}

claim || exit 0
trap 'release; log "runner down"' EXIT
log "runner up (pid $$)"
recover_stranded
idle_since=0
while :; do
  owns || { trap - EXIT; log "lock lost to another runner, exiting"; exit 0; }
  item=$(next_item)
  if [ -n "$item" ]; then
    idle_since=0
    run_item "$item"
    continue
  fi
  [ "$idle_since" -ne 0 ] || idle_since=$(date +%s)
  if [ $(( $(date +%s) - idle_since )) -ge "$IDLE" ]; then
    release
    if [ -n "$(next_item)" ] && claim; then
      idle_since=0
      continue
    fi
    trap - EXIT
    log "queue empty ${IDLE}s, runner down"
    exit 0
  fi
  sleep "$POLL"
done
