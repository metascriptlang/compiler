#!/usr/bin/env bash
# The crypto assurance suite: every test of the native MetaScript port (std/crypto/pure) on C and JavaScript, Wycheproof
# and the differential checks against the vendored C included; --slow adds the owners too slow for every run. The public
# API vectors (src/test/crypto/index.ms) stay in the land gate's tests lane, which runs them whenever std/crypto changes.
# Off by default in every gate; a heavy job, so run it through run-remote.sh from the repository root.
#
#   src/test/crypto/suite.sh [--slow]
#
# The compiler must sit in the repository root (./msc, or MSC=<root>/<name>), because a compiler loads std/ from
# beside itself and this suite tests the tree's std/, not an installed one. A host build copied in works:
#   cp "$(command -v msc)" ./hostcomp && MSC=$PWD/hostcomp src/test/crypto/suite.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root" || exit 2
slow=0
for arg in "$@"; do
	case "$arg" in
		--slow) slow=1 ;;
		*) echo "suite: unknown argument '$arg' (only --slow)" >&2; exit 2 ;;
	esac
done

msc=${MSC:-$root/msc}
[ -x "$msc" ] || { echo "suite: no compiler at $msc; build ./msc or copy one into the repository root (see the header)" >&2; exit 2; }
[ "$(cd "$(dirname "$msc")" && pwd)" = "$root" ] \
	|| { echo "suite: $msc is outside $root, so it would test its own std/, not this tree's" >&2; exit 2; }

pure=std/crypto/pure
cells=(
	"c $pure/portTests.ms"
	"js $pure/portTests.ms"
	"c $pure/portDiffTests.cms"
)
if [ "$slow" -eq 1 ]; then
	cells+=(
		"c $pure/portSlowTests.ms"
		"js $pure/portSlowTests.ms"
		"c src/test/crypto/rsaKeyGeneration.ms"
		"c src/test/crypto/pbkdf2LongVector.ms"
		"js src/test/crypto/pbkdf2LongVector.ms"
	)
fi

echo "suite: compiler $msc ($(shasum -a 256 "$msc" | cut -c1-16)), $(uname -sm), ${#cells[@]} cells"
red=0 passed=0 total=0 log=$(mktemp)
for cell in "${cells[@]}"; do
	read -r target file <<<"$cell"
	start=$SECONDS
	"$msc" test --target="$target" --tests-in-dir "$file" >"$log" 2>&1
	rc=$?
	counts=$(sed $'s/\x1b\\[[0-9;]*m//g' "$log" | awk '
		/^ *Tests +[0-9]/ { for (i = 2; i <= NF; i++) if ($i == "passed") p += $(i - 1)
			if (match($0, /\([0-9]+\)$/)) t += substr($0, RSTART + 1, RLENGTH - 2) }
		END { printf "%d %d", p, t }')
	read -r p t <<<"$counts"
	passed=$((passed + p)) total=$((total + t))
	if [ "$rc" -eq 0 ] && [ "$t" -gt 0 ] && [ "$p" -eq "$t" ]; then
		echo "ok   $target $file $p/$t $((SECONDS - start))s"
	else
		red=$((red + 1))
		echo "RED  $target $file $p/$t exit $rc $((SECONDS - start))s"
		sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E 'FAIL|error|✗|Error' | head -20 | sed 's/^/     /'
	fi
done
rm -f "$log"
echo "suite: $((${#cells[@]} - red))/${#cells[@]} cells green, $passed/$total tests passed"
[ "$red" -eq 0 ]
