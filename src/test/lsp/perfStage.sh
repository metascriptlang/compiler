#!/usr/bin/env bash
# Writes the LSP_PERF_STAGE dir that src/test/lsp/run.ms reads in a tree copied without .git:
# the revision line the runner would compute, and the pinned app archives with its pathspecs.
# Usage, from the recompiler root: src/test/lsp/perfStage.sh <dir inside the tree>
set -euo pipefail
dir=${1:?usage: perfStage.sh <dir>}
root=$(git rev-parse --show-toplevel)
workspace=$(dirname "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")")
pin() { sed -n "s/^const $1 = \"\([0-9a-f]*\)\";/\1/p" "$root/src/test/lsp/run.ms"; }
mkdir -p "$dir"; dir=$(cd "$dir" && pwd)
head=$(git rev-parse --short=12 HEAD)
dirty=$(git status --porcelain -- src/test/lsp src/compiler/lsp)
echo "recompiler@$head${dirty:++dirty}" > "$dir/revision"
archive() {
	local repo=$1 rev=$2; shift 2
	test -n "$rev" || { echo "perfStage: no pinned revision for $repo in run.ms" >&2; exit 1; }
	git -C "$workspace/$repo" archive --prefix="$repo/" -o "$dir/$repo-$rev.tar" "$rev" -- "$@"
}
archive neon "$(pin NEON_REV)" build.ms src examples/components
archive void "$(pin VOID_REV)" build.ms src ':(exclude)*.glsl.h'
archive yoga "$(pin YOGA_REV)" build.ms src
ls -l "$dir"
