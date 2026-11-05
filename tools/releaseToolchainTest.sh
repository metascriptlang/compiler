#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
source_script=${1:-$here/release.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
install="$tmp/install with spaces"
bundle="$install/msc-toolchain"
override="$tmp/explicit bundle"
trace="$tmp/compiler-called"
mkdir -p "$repo/tools" "$repo/src/compiler" "$install/bin" "$install/std/core/system"
cp "$source_script" "$repo/tools/release.sh"
printf 'export const VERSION = "0.0.0";\n' > "$repo/src/compiler/usage.ms"
: > "$install/std/core/system/index.ms"
cat > "$install/bin/msc" <<'SH'
#!/bin/sh
printf '%s\n' "$*" > "$TRACE"
exit 91
SH
for tool in zip gtar; do
    printf '#!/bin/sh\nexit 0\n' > "$install/bin/$tool"
done
chmod +x "$install/bin/msc" "$install/bin/zip" "$install/bin/gtar"
export PATH="$install/bin:$PATH" TRACE="$trace"
bad=0
checks=0
check() {
    local name=$1
    shift
    checks=$((checks + 1))
    if "$@"; then printf 'pass %s\n' "$name"
    else printf 'FAIL %s\n' "$name"; bad=$((bad + 1))
    fi
}
run_case() {
    rm -f "$trace"
    mkdir -p "$repo/out/release/.cache"
    printf 'retained\n' > "$repo/out/release/.cache/keep"
    set +e
    "$@" > "$tmp/release.log" 2>&1
    case_rc=$?
    set -e
}
for spec in \
    darwin-arm64:darwin/aarch64-macos.cfg \
    darwin-x86_64:darwin/x86_64-macos.cfg \
    linux-arm64:aarch64-linux-gnu.2.31.cfg \
    linux-x86_64:x86_64-linux-gnu.2.31.cfg \
    windows-x86_64:windows/x86_64-windows-gnu.cfg \
    windows-arm64:windows/aarch64-windows-gnu.cfg; do
    target=${spec%%:*}
    config=${spec#*:}
    mkdir -p "$bundle/runtime/$(dirname "$config")"
    : > "$bundle/runtime/$config"
    run_case env -u MSC_NATIVE_TOOLCHAIN bash "$repo/tools/release.sh" "$target"
    check "$target reaches compiler with its config" test -s "$trace"
    check "$target keeps compiler cache" test -f "$repo/out/release/.cache/keep"
done
mkdir -p "$override/runtime"
: > "$override/runtime/x86_64-linux-gnu.2.31.cfg"
rm "$bundle/runtime/x86_64-linux-gnu.2.31.cfg"
run_case env MSC_NATIVE_TOOLCHAIN="$override" bash "$repo/tools/release.sh" linux-x86_64
check 'explicit bundle overrides adjacent bundle' test -s "$trace"
check 'explicit bundle keeps compiler cache' test -f "$repo/out/release/.cache/keep"
run_case env MSC_NATIVE_TOOLCHAIN="$override" bash "$repo/tools/release.sh" linux-x86_64 windows-x86_64
check 'all target configs checked before any compile' test ! -e "$trace"
check 'missing runtime refuses release' test "$case_rc" -ne 0
check 'missing runtime names target' grep -q 'no runtime for windows-x86_64' "$tmp/release.log"
mv "$bundle" "$install/parked"
run_case env -u MSC_NATIVE_TOOLCHAIN bash "$repo/tools/release.sh" linux-x86_64
check 'missing bundle never reaches compiler' test ! -e "$trace"
check 'missing bundle names prepared toolchain' grep -q 'no prepared toolchain bundle' "$tmp/release.log"
printf 'release toolchain: %s checks, %s failures\n' "$checks" "$bad"
[ "$bad" -eq 0 ]
