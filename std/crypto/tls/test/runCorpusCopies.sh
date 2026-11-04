# Builds each corpus tls* copy (imports ../native) with $B and compares its stdout to its @stdout line.
# Usage: B=<compiler> bash std/crypto/tls/test/runCorpusCopies.sh [names...]
set -u
here=$(dirname "$0")
out=out/tlsNativeCorpus
mkdir -p "$out"
names=${*:-$(cd "$here" && ls *Native.ms | sed 's/\.ms$//')}
for n in $names; do
  ( "$B" build "$here/$n.ms" --target=c --output="$out/$n" > "$out/$n.build.log" 2>&1; echo $? > "$out/$n.build.rc" ) &
done
wait
for n in $names; do
  want=$(sed -n 's#^// @stdout: ##p' "$here/$n.ms")
  if [ "$(cat "$out/$n.build.rc")" != 0 ]; then
    echo "BUILD-FAIL $n: $(grep -m1 -i error "$out/$n.build.log" | cut -c1-300)"
    continue
  fi
  got=$(timeout 120 "$out/$n" 2>"$out/$n.err"); rc=$?
  if [ "$got" = "$want" ] && [ $rc = 0 ]; then echo "PASS $n"; else echo "FAIL $n rc=$rc"; echo "  want: $want"; echo "  got:  $got"; tail -3 "$out/$n.err" | sed 's/^/  err: /'; fi
done
