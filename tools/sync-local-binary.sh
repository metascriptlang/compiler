#!/bin/sh
# Sync locally-built msc + support trees to ~/.metascript/
# so downstream projects pick it up via $PATH.
#
# Run AFTER `msc build src/index.ms --gc=drc --danger --cc=clang --output=msc`
# See docs/DEVELOPMENT.md for the full workflow.
#
# Usage:
#   ./tools/sync-local-binary.sh                # sync all
#   ./tools/sync-local-binary.sh --no-binary    # sync only std/runtime/vendor (skip msc)
#   ./tools/sync-local-binary.sh --check        # dry-run, show what would change

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${MSC_INSTALL_DIR:-$HOME/.metascript}"

SYNC_BINARY=1
CHECK=0
for arg in "$@"; do
	case "$arg" in
		--no-binary) SYNC_BINARY=0 ;;
		--check) CHECK=1 ;;
		*) echo "unknown flag: $arg" >&2; exit 1 ;;
	esac
done

RSYNC_FLAGS="-a --delete"
[ "$CHECK" = "1" ] && RSYNC_FLAGS="$RSYNC_FLAGS --dry-run -i"

DEPLOYED_PATHS="src std runtime"
uncommitted=$(git -C "$SRC" status --porcelain -- $DEPLOYED_PATHS 2>/dev/null)
if [ -n "$uncommitted" ]; then
	echo "error: $SRC holds uncommitted work under: $DEPLOYED_PATHS" >&2
	echo "$uncommitted" | head -10 >&2
	echo "sync from a clean worktree of main: tools/wt.sh new <name>" >&2
	exit 1
fi

mkdir -p "$DEST/bin" "$DEST/std" "$DEST/runtime" "$DEST/vendor"

if [ "$SYNC_BINARY" = "1" ]; then
	if [ ! -f "$SRC/msc" ]; then
		echo "error: $SRC/msc not found. Build it first:" >&2
		echo "  cd $SRC && msc build src/index.ms --gc=drc --danger --cc=clang --output=msc" >&2
		exit 1
	fi
	src_commit_time=$(git -C "$SRC" log -1 --format=%ct -- src)
	binary_time=$(stat -f %m "$SRC/msc" 2>/dev/null || stat -c %Y "$SRC/msc")
	if [ "$binary_time" -lt "$src_commit_time" ]; then
		echo "error: $SRC/msc is older than the last commit under src/. Rebuild it first." >&2
		exit 1
	fi
	if [ -f "$DEST/bin/msc" ] && [ "$CHECK" = "0" ]; then
		cp "$DEST/bin/msc" "$DEST/bin/msc.bak-$(date +%s)"
	fi
	if [ "$CHECK" = "1" ]; then
		echo "would: cp $SRC/msc → $DEST/bin/msc"
	else
		# rm before cp: overwriting the binary in place reuses the inode, and
		# macOS AMFI still holds the old cdhash for it → new content fails
		# signature validation → SIGKILL on first run. A fresh inode avoids it.
		rm -f "$DEST/bin/msc"
		cp "$SRC/msc" "$DEST/bin/msc"
		chmod +x "$DEST/bin/msc"
		echo "synced binary → $DEST/bin/msc"
	fi
fi

# Builtin C header stubs for import-from-.h — loader resolves them at
# <compiler-root>/src/module/cparse/include, so the installed tree must
# mirror that exact path or every .h import warns "stdint.h not found".
if [ "$CHECK" = "1" ]; then
	changes=$(rsync $RSYNC_FLAGS "$SRC/src/module/cparse/include/" "$DEST/src/module/cparse/include/" 2>/dev/null | wc -l | tr -d ' ')
	echo "src/module/cparse/include/: $changes file(s) would change"
else
	mkdir -p "$DEST/src/module/cparse/include"
	rsync $RSYNC_FLAGS "$SRC/src/module/cparse/include/" "$DEST/src/module/cparse/include/" >/dev/null 2>&1
	echo "synced src/module/cparse/include/ → $DEST/src/module/cparse/include/"
fi

# std/ and runtime/ are deployed as-is (mirror source).
for tree in std runtime; do
	if [ "$CHECK" = "1" ]; then
		changes=$(rsync $RSYNC_FLAGS "$SRC/$tree/" "$DEST/$tree/" 2>/dev/null | wc -l | tr -d ' ')
		echo "$tree/: $changes file(s) would change"
	else
		rsync $RSYNC_FLAGS "$SRC/$tree/" "$DEST/$tree/" >/dev/null 2>&1
		echo "synced $tree/ → $DEST/$tree/"
	fi
done

# vendor/ — only the 4 production libs the compiler actually links against.
# (Source tree has ~14 vendored projects; release.sh curates this same subset
# via @compile directives in std/. See tools/release.sh collect_vendor().)
for lib in argon2 mbedtls miniz monocypher; do
	if [ ! -d "$SRC/vendor/$lib" ]; then continue; fi
	if [ -z "$(ls -A "$SRC/vendor/$lib")" ]; then
		echo "error: $SRC/vendor/$lib is empty; syncing it would delete the installed copy" >&2
		exit 1
	fi
	if [ "$CHECK" = "1" ]; then
		changes=$(rsync $RSYNC_FLAGS --copy-links "$SRC/vendor/$lib/" "$DEST/vendor/$lib/" 2>/dev/null | wc -l | tr -d ' ')
		echo "vendor/$lib/: $changes file(s) would change"
	else
		mkdir -p "$DEST/vendor/$lib"
		rsync $RSYNC_FLAGS --copy-links "$SRC/vendor/$lib/" "$DEST/vendor/$lib/" >/dev/null 2>&1
		echo "synced vendor/$lib/ → $DEST/vendor/$lib/"
	fi
done

record_build() {
	key="$1"
	stamp="$(git -C "$SRC" log -1 --format='%h %cI')"
	touch "$DEST/BUILD"
	grep -v "^$key " "$DEST/BUILD" > "$DEST/BUILD.next" || true
	echo "$key $stamp" >> "$DEST/BUILD.next"
	mv "$DEST/BUILD.next" "$DEST/BUILD"
}

if [ "$CHECK" != "1" ]; then
	[ "$SYNC_BINARY" = "1" ] && record_build binary
	record_build support
	echo ""
	"$DEST/bin/msc" --version
	cat "$DEST/BUILD"
fi
