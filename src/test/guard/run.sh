#!/usr/bin/env bash
# nim-guard runner — proactive guards against silent drift from the Nim
# memory-management / lifecycle model (complements the reactive /trace-nim).
#
# Each *.ms here is a probe that exercises ONE Nim-derived invariant. It is
# built with the DRC ledger (-DMS_DRC_LEDGER, a test-only instrumentation that
# aborts on the 2nd finalize of a live object and dumps per-type alloc/destroy
# balance at exit). A guard passes iff: clean exit, no DOUBLE-DESTROY, and every
# declared per-type balance holds. A red guard means a refactor drifted from the
# Nim model the probe cites — run /trace-nim on the named type.
#
# Directives in a probe's header comments (optional):
#   // GUARD-BALANCE <MangledType>   assert alloc==destroy for that type at exit
# The double-destroy abort needs no directive — it is name-agnostic.
#
# Env: MSC=<path to msc> (default: msc)   GUARD_GC="drc orc" (default both)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
MSC="${MSC:-msc}"
MODES="${GUARD_GC:-drc orc}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

for ms in "$DIR"/*.ms; do
  [ -e "$ms" ] || continue
  name="$(basename "$ms" .ms)"
  balance=$(grep -oE '// *GUARD-BALANCE +[A-Za-z0-9_]+' "$ms" | awk '{print $NF}')
  checkfails=$(grep -E '^// GUARD-CHECK-FAIL ' "$ms" | sed -E 's|^// GUARD-CHECK-FAIL ||')
  for gc in $MODES; do
    bin="$TMP/$name.$gc"
    if [ -n "$checkfails" ]; then
      # errorcheck guard: build MUST fail at check, log MUST carry every tag.
      # Compiling clean means a checker rule was silently dropped.
      if "$MSC" build "$ms" --gc="$gc" --passC="-DMS_DRC_LEDGER" --output="$bin" \
           >"$TMP/$name.$gc.build" 2>&1; then
        echo "FAIL $name [$gc]: compiled clean — a checker rule was dropped"
        fail=1; continue
      fi
      ok=1
      while IFS= read -r want; do
        [ -z "$want" ] && continue
        if ! grep -qF "$want" "$TMP/$name.$gc.build"; then
          echo "FAIL $name [$gc]: missing diagnostic: $want"; ok=0; fail=1
        fi
      done <<<"$checkfails"
      [ $ok -eq 1 ] && echo "ok   $name [$gc]"
      continue
    fi
    if ! "$MSC" build "$ms" --gc="$gc" --passC="-DMS_DRC_LEDGER" --output="$bin" \
         >"$TMP/$name.$gc.build" 2>&1; then
      echo "FAIL $name [$gc]: build error"; grep -iE '^error' "$TMP/$name.$gc.build" | head -3
      fail=1; continue
    fi
    "$bin" >"$TMP/$name.$gc.out" 2>"$TMP/$name.$gc.err"; rc=$?
    if [ $rc -ne 0 ] || grep -q 'DOUBLE-DESTROY' "$TMP/$name.$gc.err"; then
      echo "FAIL $name [$gc]: $(grep -m1 'DOUBLE-DESTROY' "$TMP/$name.$gc.err" || echo "exit=$rc")"
      echo "     -> drift from Nim last-ref dispose model; run /trace-nim on the named type"
      fail=1; continue
    fi
    ok=1
    for t in $balance; do
      line=$(grep -E "^LEDGER $t " "$TMP/$name.$gc.err" | tail -1)
      a=$(echo "$line" | sed -nE 's/.*alloc=([0-9]+).*/\1/p')
      d=$(echo "$line" | sed -nE 's/.*destroy=([0-9]+).*/\1/p')
      if [ -z "$a" ] || [ "$a" != "$d" ]; then
        echo "FAIL $name [$gc]: imbalance $t alloc=${a:-?} destroy=${d:-?}"; ok=0; fail=1
      fi
    done
    [ $ok -eq 1 ] && echo "ok   $name [$gc]"
  done
done

[ $fail -eq 0 ] && echo "nim-guard: ALL GREEN" || echo "nim-guard: FAILURES ABOVE"
exit $fail
