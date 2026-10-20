#!/bin/bash
# usage: tools/smith/campaign.sh <batch file> <run dir>
# A batch line is name|first|count|flags. Each batch waits for a quiet machine and
# for <run dir>/hold to go away, and is skipped once <run dir>/<name>.done exists.
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
batches=$1
run=$2
mkdir -p "$run"
export MSC=${MSC:-$HOME/.metascript/bin/msc} MSCORPUS_JOBS=${MSCORPUS_JOBS:-4} MSCORPUS_RAISER=1
trap 'trap - INT TERM; kill 0' INT TERM
quiet() {
	[ -z "$(ls "$HOME/.metascript/gates" 2>/dev/null)" ] || return 1
	[ "$(sysctl -n vm.loadavg | awk '{print int($3)}')" -lt 14 ] || return 1
	[ "$(df -g / | tail -1 | awk '{print $4}')" -ge 30 ]
}
while IFS='|' read -r name first count flags; do
	[ -z "$name" ] && continue
	[ -f "$run/$name.done" ] && continue
	until quiet && [ ! -f "$run/hold" ]; do sleep 60; done
	ls out/smith/bundles > "$run/$name.before" 2>/dev/null
	echo "BEGIN $name $(date +%FT%T) load=$(sysctl -n vm.loadavg)" >> "$run/campaign.log"
	s=$(date +%s)
	bash -c "msc run tools/smith/main.ms run $first $count $flags" > "$run/$name.log" 2>&1
	rc=$?
	echo "END $name $(date +%FT%T) wall=$(( $(date +%s) - s ))s exit=$rc" >> "$run/campaign.log"
	ls out/smith/bundles > "$run/$name.after" 2>/dev/null
	comm -13 "$run/$name.before" "$run/$name.after" > "$run/$name.new"
	touch "$run/$name.done"
done < "$batches"
echo "ALL DONE $(date +%FT%T)" >> "$run/campaign.log"
