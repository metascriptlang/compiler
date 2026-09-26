#!/usr/bin/env bash
set -u
Q=${MSC_LAND_QUEUE:-$HOME/metascript/.wt/queue}
WT_TOOL=${MSC_WT_TOOL:-$HOME/nerdtools/claude/tools/wt.sh}
mkdir -p "$Q"
if [ -f "$Q/runner.pid" ] && kill -0 "$(cat "$Q/runner.pid")" 2>/dev/null; then
  exit 0
fi
printf '%s\n' $$ >"$Q/runner.pid"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$Q/runner.log"; }
busy() { tasklist 2>/dev/null | awk 'NR>2 {print $1}' | grep -ixE 'msc(\.exe)?|msc\.cand|msc\.self|zig\.exe|cc1\.exe|cc1plus\.exe|clang\.exe' | grep -q .; }
idle_since=0
log "runner up (pid $$)"
trap 'rm -f "$Q/runner.pid"; log "runner down"' EXIT
while :; do
  item=$(ls "$Q"/*.item 2>/dev/null | sort | head -1)
  if [ -z "$item" ]; then
    [ "$idle_since" -eq 0 ] && idle_since=$(date +%s)
    [ $(( $(date +%s) - idle_since )) -lt 600 ] || { log "queue empty 10m, exiting"; exit 0; }
    sleep 20
    continue
  fi
  idle_since=0
  name=$(sed -n 's/^name=//p' "$item")
  worktree=$(sed -n 's/^worktree=//p' "$item")
  if [ ! -d "$worktree" ] || [ -n "$(git -C "$worktree" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    log "$name: worktree gone or dirty, dropping item"
    mv "$item" "$item.dropped"
    continue
  fi
  while busy; do sleep 60; done
  old=$(git -C "$worktree" rev-parse --verify main 2>/dev/null || true)
  log "$name: gate --base ${old:-?}"
  if (cd "$worktree" && tools/gate.sh --base "$old") >>"$Q/$name.gate.log" 2>&1; then
    rm -f "$item" "$Q/$name.red"
    if out=$(WT_CWD="$worktree" bash "$WT_TOOL" land "$name" --no-gate 2>&1); then
      log "$name: $out"
    else
      log "$name: LAND FAILED after green gate: $out"
    fi
  else
    mv "$item" "$item.reditem"
    tail -5 "$Q/$name.gate.log" >"$Q/$name.red"
    log "$name: gate RED, main untouched — see queue/$name.red"
  fi
done
