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
#   // GUARD-BALANCE-ORC <MangledType>  same, but under orc only (cycle leaks are by-design under drc/ARC)
#   // GUARD-JS                      also build --target=js + node-run; pass = exit 0 + GUARD-OK printed
#   // GUARD-OS <os>                 one [<os>] lane instead: build --os=<os>; with GUARD-CHECK-FAIL the
#                                    build must fail with every tag, else it must link (nothing is run)
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
export MSC
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
  # run.ms is the cross-platform port of this script, not a probe — running it
  # here nests a second full guard pass (and its out/guard/work builds collide).
  [ "$name" = "run" ] && continue
  balance=$(grep -oE '// *GUARD-BALANCE +[A-Za-z0-9_]+' "$ms" | awk '{print $NF}')
  balanceOrc=$(grep -oE '// *GUARD-BALANCE-ORC +[A-Za-z0-9_]+' "$ms" | awk '{print $NF}')
  checkfails=$(grep -E '^// GUARD-CHECK-FAIL ' "$ms" | sed -E 's|^// GUARD-CHECK-FAIL ||')
  wantjs=$(grep -cE '^// GUARD-JS' "$ms" || true)
  testbal=$(grep -oE '// *GUARD-TEST-BALANCE +[A-Za-z0-9_]+' "$ms" | awk '{print $NF}')
  os=$(grep -oE '^// GUARD-OS +[a-z]+' "$ms" | awk '{print $NF}')
  if [ -n "$os" ]; then
    if [ -n "$balance$balanceOrc$testbal" ] || [ "$wantjs" != "0" ]; then
      echo "FAIL $name [$os]: GUARD-OS builds a binary the host cannot run; drop GUARD-BALANCE/GUARD-JS/GUARD-TEST-BALANCE"
      fail=1; continue
    fi
    oslog="$TMP/$name.$os.build"
    if ( cd "$WORK" && "$MSC" build "$ms" --os="$os" --output="$TMP/$name.$os" ) >"$oslog" 2>&1; then
      if [ -n "$checkfails" ]; then
        echo "FAIL $name [$os]: compiled clean — a checker rule was dropped"; fail=1
      else
        echo "ok   $name [$os]"
      fi
      continue
    fi
    if [ -z "$checkfails" ]; then
      echo "FAIL $name [$os]: build error"; grep -E '^(ld\.lld: )?error' "$oslog" | head -3
      fail=1; continue
    fi
    ok=1
    while IFS= read -r want; do
      [ -z "$want" ] && continue
      if ! grep -qF "$want" "$oslog"; then
        echo "FAIL $name [$os]: missing diagnostic: $want"; ok=0; fail=1
      fi
    done <<<"$checkfails"
    [ $ok -eq 1 ] && echo "ok   $name [$os]"
    continue
  fi
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
    # GUARD-BALANCE always; GUARD-BALANCE-ORC only under orc (cycle leaks are
    # by-design under drc/ARC, like Nim — assert collection only where ORC runs).
    eff="$balance"
    [ "$gc" = "orc" ] && eff="$eff $balanceOrc"
    for t in $eff; do
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
  if [ "$wantjs" != "0" ] && [ -n "$checkfails" ]; then
    # errorcheck guard on the js target: the silent-accept half. Compiling
    # clean here means js runs the rejected construct with no diagnostic.
    jsout="$TMP/$name.mjs.js"
    if ( cd "$WORK" && "$MSC" build "$ms" --target=js --output="$jsout" ) >"$TMP/$name.js.build" 2>&1; then
      echo "FAIL $name [js]: compiled clean — a checker rule was dropped"
      fail=1
    else
      ok=1
      while IFS= read -r want; do
        [ -z "$want" ] && continue
        if ! grep -qF "$want" "$TMP/$name.js.build"; then
          echo "FAIL $name [js]: missing diagnostic: $want"; ok=0; fail=1
        fi
      done <<<"$checkfails"
      [ $ok -eq 1 ] && echo "ok   $name [js]"
    fi
  elif [ "$wantjs" != "0" ]; then
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
  # // GUARD-TEST-BALANCE <T>: the invariant lives in the TEST lane — run the
  # file under `msc test` with the ledger on and assert T balances from the
  # test binary's own output. Guards the analyzer's TestDecl arm: without it
  # test bodies are never processed and every owned value leaks (alloc>0,
  # destroy=0), so `msc test` silently ran with different memory semantics
  # than `msc build`.
  if [ -n "$testbal" ]; then
    ( cd "$WORK" && "$MSC" test "$ms" --passC="-DMS_DRC_LEDGER" ) >"$TMP/$name.test.log" 2>&1
    trc=$?
    ok=1
    if [ $trc -ne 0 ]; then
      echo "FAIL $name [test]: msc test exit=$trc"; ok=0; fail=1
    fi
    for t in $testbal; do
      line=$(grep -E "^LEDGER $t " "$TMP/$name.test.log" | tail -1)
      a=$(echo "$line" | sed -nE 's/.*alloc=([0-9]+).*/\1/p')
      d=$(echo "$line" | sed -nE 's/.*destroy=([0-9]+).*/\1/p')
      if [ -z "$a" ] || [ "$a" != "$d" ]; then
        echo "FAIL $name [test]: imbalance $t alloc=${a:-?} destroy=${d:-?}"; ok=0; fail=1
      fi
    done
    [ $ok -eq 1 ] && echo "ok   $name [test]"
  fi
done

# DCE emit-clean guard: a hello-world build must carry no websocket/crypto
# symbols in its emitted C — dead-module pruning + edge-based hook aliveness
# (NIM-REF CG-1). Proven-red on any pre-tier-2 compiler:
# name-based hook exemptions keep those modules alive in every program.
emitname="helloEmitClean"
printf 'console.log("hi");\n' > "$TMP/hello_emit.ms"
if ! ( cd "$TMP" && "$MSC" build hello_emit.ms --gc=drc --output="$TMP/hello_emit_bin" ) >"$TMP/$emitname.build" 2>&1; then
  echo "FAIL $emitname: build error"; fail=1
else
  hits=$(nm "$TMP/hello_emit_bin" 2>/dev/null | grep -ci "websocket\|mbedtls\|psa_")
  if [ "$hits" -gt 0 ]; then
    echo "FAIL $emitname: $hits dead websocket/crypto symbols in hello binary"; fail=1
  else
    echo "ok   $emitname"
  fi
fi

# `msc build` never runs a `test` block, so this can only be a gate: an inline
# guard test here is green whatever the loader does.
giname="preludeUserModule"
mkdir -p "$TMP/gi"
printf 'const config = {\n\tglobalImports: ["%s/fixtures/preludeUserModule"],\n};\nexport default config;\n' "$DIR" > "$TMP/gi/build.ms"
printf 'console.log(neonGuardPreludeProbe());\n' > "$TMP/gi/main.ms"
if ( cd "$TMP/gi" && "$MSC" run main.ms ) >"$TMP/$giname.log" 2>&1; then
  if grep -qx '42' "$TMP/$giname.log"; then
    echo "ok   $giname"
  else
    echo "FAIL $giname: globalImports symbol never reached the entry module"; fail=1
  fi
else
  echo "FAIL $giname: exit=$?"; grep -iE '^error' "$TMP/$giname.log" | head -3; fail=1
fi

slname="preludeSymlinkedModule"
mkdir -p "$TMP/gisym"
ln -sf "$DIR/fixtures/preludeUserModule.ms" "$TMP/gisym/gi.ms"
printf 'const config = {\n\tglobalImports: ["./gi"],\n};\nexport default config;\n' > "$TMP/gisym/build.ms"
printf 'console.log(neonGuardPreludeProbe());\n' > "$TMP/gisym/main.ms"
if ( cd "$TMP/gisym" && "$MSC" run main.ms ) >"$TMP/$slname.log" 2>&1; then
  if grep -qx '42' "$TMP/$slname.log"; then
    echo "ok   $slname"
  else
    echo "FAIL $slname: globalImports symbol never reached the entry module"; fail=1
  fi
else
  echo "FAIL $slname: exit=$? — the entry was matched by spelling, not by module identity"
  grep -iE '^error' "$TMP/$slname.log" | head -3; fail=1
fi

# A FRESH process is load-bearing: any earlier in-process prelude build warms
# the memo and hides the recursion, so this cannot become an inline test.
pmcname="preludeMacroCycle"
PMC_TIMEOUT=""
command -v timeout >/dev/null 2>&1 && PMC_TIMEOUT="timeout 240"
[ -z "$PMC_TIMEOUT" ] && command -v gtimeout >/dev/null 2>&1 && PMC_TIMEOUT="gtimeout 240"
mkdir -p "$TMP/pmc"
printf 'const config = {\n\tglobalImports: ["%s/fixtures/preludeMacroCycle/gi"],\n};\nexport default config;\n' "$DIR" > "$TMP/pmc/build.ms"
printf 'console.log(preludeMacroCycleProbe());\n' > "$TMP/pmc/main.ms"
if ( cd "$TMP/pmc" && $PMC_TIMEOUT "$MSC" run main.ms ) >"$TMP/$pmcname.log" 2>&1; then
  if grep -qx '42' "$TMP/$pmcname.log"; then
    echo "ok   $pmcname"
  else
    echo "FAIL $pmcname: macro-emitted declaration never reached the entry module"; fail=1
  fi
else
  rc=$?
  if [ $rc -eq 124 ]; then
    echo "FAIL $pmcname: hung — the engine rebuilt the user prelude it was already loading"
  else
    echo "FAIL $pmcname: exit=$rc"; grep -iE '^error' "$TMP/$pmcname.log" | head -3
  fi
  fail=1
fi

[ $fail -eq 0 ] && echo "nim-guard: ALL GREEN" || echo "nim-guard: FAILURES ABOVE"
exit $fail
