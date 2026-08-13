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
#   // GUARD-JS                      also build --target=js + node-run; pass = exit 0 + GUARD-OK printed
# The double-destroy abort needs no directive — it is name-agnostic.
#
# Env: MSC=<path to msc> (default: msc)   GUARD_GC="drc orc" (default both)
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
# Compiler UNDER TEST: ./msc (the freshly built binary) when present, else the
# installed msc; MSC=<path> overrides. Made absolute because probes build from
# a private sandbox below.
[ -n "${MSC:-}" ] || { [ -x ./msc ] && MSC=./msc; }
MSC="${MSC:-msc}"
case "$MSC" in */*) MSC="$(cd "$(dirname "$MSC")" && pwd)/$(basename "$MSC")";; esac
echo "nim-guard: compiler under test = $MSC"
MODES="${GUARD_GC:-drc orc}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

# `out/<mode>/.cache` is resolved against the CWD, so building from the repo root
# shares the object cache with any other msc invocation there — a concurrent
# build writing the same .o mid-read produced link errors on a DIFFERENT probe
# every run. Build from a private sandbox instead; the content-addressed global
# cache (~/.metascript/cache/objects) keeps it warm.
WORK="$TMP/work"; mkdir -p "$WORK"
INFRA_RE="_link\.rsp': FileNotFound|UnexpectedRemainder|NotLibStub|failed to resolve relocations"

# build <ms> <gc> <bin> <log>; retries once on a toolchain-race signature so
# infra noise can't be mistaken for drift, and says so out loud when it does.
build() {
  ( cd "$WORK" && "$MSC" build "$1" --gc="$2" --passC="-DMS_DRC_LEDGER" --output="$3" ) >"$4" 2>&1 && return 0
  grep -qE "$INFRA_RE" "$4" || return 1
  echo "     flake-retry $(basename "$1" .ms) [$2]: toolchain race, rebuilding clean"
  rm -rf "$WORK"/out
  ( cd "$WORK" && "$MSC" build "$1" --gc="$2" --passC="-DMS_DRC_LEDGER" --output="$3" ) >"$4" 2>&1
}

for ms in "$DIR"/*.ms; do
  [ -e "$ms" ] || continue
  name="$(basename "$ms" .ms)"
  balance=$(grep -oE '// *GUARD-BALANCE +[A-Za-z0-9_]+' "$ms" | awk '{print $NF}')
  checkfails=$(grep -E '^// GUARD-CHECK-FAIL ' "$ms" | sed -E 's|^// GUARD-CHECK-FAIL ||')
  wantjs=$(grep -cE '^// GUARD-JS' "$ms" || true)
  for gc in $MODES; do
    bin="$TMP/$name.$gc"
    if [ -n "$checkfails" ]; then
      # errorcheck guard: build MUST fail at check, log MUST carry every tag.
      # Compiling clean means a checker rule was silently dropped.
      if build "$ms" "$gc" "$bin" "$TMP/$name.$gc.build"; then
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
    if ! build "$ms" "$gc" "$bin" "$TMP/$name.$gc.build"; then
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
  # // GUARD-JS: the invariant also lives in the node bundle — build for the JS
  # target and run it; pass iff exit 0 AND the probe printed GUARD-OK (values
  # are printed before the checks, so a red run shows what it saw).
  if [ "$wantjs" != "0" ]; then
    jsout="$TMP/$name.mjs.js"
    if ! ( cd "$WORK" && "$MSC" build "$ms" --target=js --output="$jsout" ) >"$TMP/$name.js.build" 2>&1; then
      echo "FAIL $name [js]: build error"; grep -iE '^error' "$TMP/$name.js.build" | head -3
      fail=1
    else
      node "$jsout" >"$TMP/$name.js.out" 2>&1; rc=$?
      if [ $rc -ne 0 ] || ! grep -q 'GUARD-OK' "$TMP/$name.js.out"; then
        echo "FAIL $name [js]: exit=$rc last='$(tail -1 "$TMP/$name.js.out")'"
        fail=1
      else
        echo "ok   $name [js]"
      fi
    fi
  fi
done

[ $fail -eq 0 ] && echo "nim-guard: ALL GREEN" || echo "nim-guard: FAILURES ABOVE"
exit $fail
