#!/usr/bin/env bash
# Release build script for MetaScript compiler
# Builds all targets, packages as .tar.gz, uploads to GitHub Releases.
#
# Usage:
#   ./tools/release.sh                       # Build all targets
#   ./tools/release.sh darwin-arm64          # Build single target
#   ./tools/release.sh --upload              # Build all + upload to GitHub
#   ./tools/release.sh --upload darwin-arm64 # Build one + upload
#
# Requires: bun, zig, tar, gh (for --upload)
# Output: dist/msc-<version>-<os>-<arch>.tar.gz
#
# Archive naming matches install.sh expectations:
#   os:   darwin | linux | windows
#   arch: arm64 | x86_64
#
# Release workflow
# ----------------
# Every release ships as a GitHub Pre-release. Stable users are not affected
# until you manually promote a release to "Latest".
#
#   1. Bump VERSION in src/compiler/usage.ms
#   2. ./tools/release.sh --upload     (publishes as pre-release)
#   3. Test the new build
#   4. When satisfied, promote it manually:
#        gh release edit v<VERSION> --latest=true --prerelease=false
#
# Power users can install a specific pre-release with:
#   curl -fsSL https://metascriptlang.org/install.sh | MSC_VERSION=<version> sh
#
# Stable users always get whatever's currently marked "Latest" via:
#   curl -fsSL https://metascriptlang.org/install.sh | sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# Extract version from usage.ms
VERSION=$(grep 'export const VERSION' src/compiler/usage.ms | sed 's/.*"\(.*\)".*/\1/')
if [ -z "$VERSION" ]; then
    echo "error: could not extract VERSION from src/compiler/usage.ms"
    exit 1
fi

DIST_DIR="$ROOT/dist"
STAGE_DIR="$DIST_DIR/stage"
UPLOAD=false

# All supported targets (install.sh naming: os-arch)
ALL_TARGETS=(
    darwin-arm64
    darwin-x86_64
    linux-arm64
    linux-x86_64
    windows-x86_64
    windows-arm64
)

# Parse arguments
TARGETS=()
for arg in "$@"; do
    if [ "$arg" = "--upload" ]; then
        UPLOAD=true
    else
        TARGETS+=("$arg")
    fi
done
if [ ${#TARGETS[@]} -eq 0 ]; then
    TARGETS=("${ALL_TARGETS[@]}")
fi

# Validate targets
for t in "${TARGETS[@]}"; do
    valid=false
    for a in "${ALL_TARGETS[@]}"; do
        if [ "$t" = "$a" ]; then valid=true; break; fi
    done
    if [ "$valid" = false ]; then
        echo "error: unknown target '$t'"
        echo "  Valid targets: ${ALL_TARGETS[*]}"
        exit 1
    fi
done

# Check prerequisites
for cmd in bun zig zip; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "error: $cmd is required but not found in PATH"
        exit 1
    fi
done

# Pick the tar implementation. macOS ships BSD tar, which unconditionally
# embeds `com.apple.provenance` and other LIBARCHIVE.xattr.* headers in pax
# archives. GNU tar on Linux/Windows warns "Ignoring unknown extended header
# keyword" for each entry during extraction. Requiring GNU tar on macOS
# (brew install gnu-tar, exposes `gtar`) produces clean archives that install
# quietly everywhere. Linux hosts already ship GNU tar as `tar`.
if [ "$(uname -s)" = "Darwin" ]; then
    if command -v gtar &>/dev/null; then
        TAR=gtar
    else
        echo "error: GNU tar required on macOS to avoid Apple xattr headers"
        echo "  install with: brew install gnu-tar"
        exit 1
    fi
else
    TAR=tar
fi

if [ "$UPLOAD" = true ] && ! command -v gh &>/dev/null; then
    echo "error: gh (GitHub CLI) is required for --upload but not found in PATH"
    exit 1
fi

echo "MetaScript release build v${VERSION}"
echo "Targets: ${TARGETS[*]}"
[ "$UPLOAD" = true ] && echo "Upload: GitHub Releases"
echo ""

# Detect host platform for native vs cross builds
HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
HOST_CPU="$(uname -m)"
case "$HOST_CPU" in
    aarch64) HOST_CPU="arm64" ;;
esac
HOST_TARGET="${HOST_OS}-${HOST_CPU}"

# Map install.sh target names to msc --os/--cpu flags
target_to_msc_flags() {
    local os="${1%-*}"
    local arch="${1#*-}"
    # msc --os uses: macos (not darwin)
    local msc_os="$os"
    [ "$os" = "darwin" ] && msc_os="macos"
    # msc --cpu uses: amd64 (not x86_64)
    local msc_cpu="$arch"
    [ "$arch" = "x86_64" ] && msc_cpu="amd64"
    echo "--os=$msc_os --cpu=$msc_cpu"
}

# Collect std/ files: only .ms and .cms, excluding test.ms and CLAUDE.md
collect_std() {
    local dest="$1"
    find "$ROOT/std" \( -name "*.ms" -o -name "*.cms" \) \
        ! -name "test.ms" ! -name "CLAUDE.md" \
        -print0 | while IFS= read -r -d '' f; do
        local rel="${f#$ROOT/}"
        mkdir -p "$(dirname "$dest/$rel")"
        cp "$f" "$dest/$rel"
    done
}

# Collect runtime/ files: only .h and .c
collect_runtime() {
    local dest="$1"
    find "$ROOT/runtime" \( -name "*.h" -o -name "*.c" \) -print0 | while IFS= read -r -d '' f; do
        local rel="${f#$ROOT/}"
        mkdir -p "$(dirname "$dest/$rel")"
        cp "$f" "$dest/$rel"
    done
}

# Collect vendor files referenced by @compile in std/
collect_vendor() {
    local dest="$1"

    # Extract unique vendor paths from @compile directives in std/
    local vendor_files
    vendor_files=$(grep -r '@compile' "$ROOT/std/" 2>/dev/null \
        | grep 'vendor/' \
        | sed 's/.*@compile("\(vendor\/[^"]*\)").*/\1/' \
        | sort -u)

    for vf in $vendor_files; do
        if [ -f "$ROOT/$vf" ]; then
            mkdir -p "$(dirname "$dest/$vf")"
            cp "$ROOT/$vf" "$dest/$vf"
        else
            echo "  warn: vendor file not found: $vf"
        fi
    done

    # mbedtls public include dirs (matching -I paths in std/crypto/tls/index.cms)
    for inc in \
        "vendor/mbedtls/include" \
        "vendor/mbedtls/tf-psa-crypto/include" \
        "vendor/mbedtls/tf-psa-crypto/drivers/builtin/include"; do
        if [ -d "$ROOT/$inc" ]; then
            mkdir -p "$(dirname "$dest/$inc")"
            cp -r "$ROOT/$inc" "$dest/$inc"
        fi
    done
    # mbedtls private headers (library/*.h, tf-psa-crypto/core/*.h, drivers/builtin/src/*.h)
    for dir in \
        "vendor/mbedtls/library" \
        "vendor/mbedtls/tf-psa-crypto/core" \
        "vendor/mbedtls/tf-psa-crypto/drivers/builtin/src"; do
        for hdr in "$ROOT/$dir/"*.h; do
            [ -f "$hdr" ] || continue
            mkdir -p "$dest/$dir"
            cp "$hdr" "$dest/$dir/"
        done
    done

    # monocypher headers
    for dir in "vendor/monocypher/src" "vendor/monocypher/src/optional"; do
        for hdr in "$ROOT/$dir/"*.h; do
            [ -f "$hdr" ] || continue
            mkdir -p "$dest/$dir"
            cp "$hdr" "$dest/$dir/"
        done
    done

    # argon2 headers
    if [ -d "$ROOT/vendor/argon2/include" ]; then
        mkdir -p "$dest/vendor/argon2"
        cp -r "$ROOT/vendor/argon2/include" "$dest/vendor/argon2/include"
    fi
    for hdr in "$ROOT/vendor/argon2/src/"*.h "$ROOT/vendor/argon2/src/blake2/"*.h; do
        [ -f "$hdr" ] || continue
        local rel="${hdr#$ROOT/}"
        mkdir -p "$(dirname "$dest/$rel")"
        cp "$hdr" "$dest/$rel"
    done

    # miniz headers
    for hdr in "$ROOT/vendor/miniz/"*.h; do
        [ -f "$hdr" ] || continue
        mkdir -p "$dest/vendor/miniz"
        cp "$hdr" "$dest/vendor/miniz/"
    done
}

# Build a single target
build_target() {
    local target="$1"
    local os="${target%-*}"
    local arch="${target#*-}"
    local ext=""
    [ "$os" = "windows" ] && ext=".exe"

    local archive_name="msc-${VERSION}-${os}-${arch}"
    local stage="$STAGE_DIR/$archive_name"

    echo "==> Building $target"

    # Clean staging area for this target
    rm -rf "$stage"
    mkdir -p "$stage/bin"

    # Determine if this is a native or cross build
    local cross_flags=""
    if [ "$target" != "$HOST_TARGET" ]; then
        cross_flags=$(target_to_msc_flags "$target")
        echo "  cross-compile: $HOST_TARGET -> $target (zig cc)"
    else
        echo "  native build"
    fi

    # Compile
    rm -rf out
    echo "  compiling..."
    # shellcheck disable=SC2086
    if ! bun run run-ms build src/index.ms --release --strip --gc=drc $cross_flags --time 2>&1 | tee "$DIST_DIR/${archive_name}.log" | tail -5; then
        echo "  FAILED — see $DIST_DIR/${archive_name}.log"
        return 1
    fi

    # Find the output binary
    local bin_path="out/release/index${ext}"
    if [ ! -f "$bin_path" ]; then
        echo "  error: expected output at $bin_path not found"
        return 1
    fi

    # Copy binary
    cp "$bin_path" "$stage/bin/msc${ext}"
    echo "  binary: $(ls -lh "$stage/bin/msc${ext}" | awk '{print $5}')"

    # Collect support files
    echo "  collecting std/..."
    collect_std "$stage"

    echo "  collecting runtime/..."
    collect_runtime "$stage"

    echo "  collecting vendor/..."
    collect_vendor "$stage"

    # Package: .zip for Windows (convention + native double-click support),
    # .tar.gz for macOS/Linux (preserves symlinks, executable bit, smaller).
    echo "  packaging..."
    local archive_path
    if [ "$os" = "windows" ]; then
        archive_path="$DIST_DIR/${archive_name}.zip"
        (cd "$stage" && zip -qr "$archive_path" .)
    else
        archive_path="$DIST_DIR/${archive_name}.tar.gz"
        "$TAR" -czf "$archive_path" -C "$stage" .
    fi

    local size
    size=$(ls -lh "$archive_path" | awk '{print $5}')
    echo "  -> ${archive_path#$ROOT/} ($size)"
    echo ""

    # Clean staging
    rm -rf "$stage"
}

# Upload to GitHub Releases
upload_release() {
    local tag="v${VERSION}"

    echo "==> Uploading to GitHub Releases ($tag)"

    # Collect all archives for this version (.tar.gz for Unix, .zip for Windows)
    local assets=()
    for f in "$DIST_DIR"/msc-"${VERSION}"-*.tar.gz "$DIST_DIR"/msc-"${VERSION}"-*.zip; do
        [ -f "$f" ] && assets+=("$f")
    done

    if [ ${#assets[@]} -eq 0 ]; then
        echo "  error: no archives found to upload"
        return 1
    fi

    # Create release (or update if exists)
    if gh release view "$tag" &>/dev/null; then
        # Refuse to overwrite a release that's currently marked Latest —
        # that would silently ship untested binaries to stable users.
        # If a hotfix without bumping version is genuinely needed, demote first:
        #   gh release edit "$tag" --latest=false --prerelease
        is_latest=$(gh release view "$tag" --json isLatest --jq '.isLatest' 2>/dev/null)
        if [ "$is_latest" = "true" ]; then
            echo "  error: Release $tag is currently marked Latest."
            echo "         Refusing to overwrite stable assets."
            echo "         Bump VERSION in src/compiler/usage.ms before re-running."
            return 1
        fi
        echo "  release $tag exists, uploading assets..."
        gh release upload "$tag" "${assets[@]}" --clobber
    else
        echo "  creating release $tag..."
        gh release create "$tag" "${assets[@]}" \
            --prerelease \
            --title "MetaScript $tag" \
            --notes "$(cat <<EOF
## MetaScript Compiler $tag

### Installation

\`\`\`sh
curl -fsSL https://metascriptlang.org/install.sh | sh
\`\`\`

### Downloads

| Platform | Architecture | Archive |
|----------|-------------|---------|
| macOS | Apple Silicon (arm64) | msc-${VERSION}-darwin-arm64.tar.gz |
| macOS | Intel (x86_64) | msc-${VERSION}-darwin-x86_64.tar.gz |
| Linux | arm64 | msc-${VERSION}-linux-arm64.tar.gz |
| Linux | x86_64 | msc-${VERSION}-linux-x86_64.tar.gz |
| Windows | x86_64 | msc-${VERSION}-windows-x86_64.zip |
| Windows | arm64 | msc-${VERSION}-windows-arm64.zip |
EOF
)"
    fi

    echo "  done."
    echo ""
}

# Main
mkdir -p "$DIST_DIR"

failed=0
for target in "${TARGETS[@]}"; do
    if ! build_target "$target"; then
        failed=$((failed + 1))
    fi
done

# Summary
echo "================================"
if [ $failed -eq 0 ]; then
    echo "All ${#TARGETS[@]} target(s) built successfully."
    echo ""
    echo "Archives:"
    for target in "${TARGETS[@]}"; do
        _os="${target%-*}"
        _arch="${target#*-}"
        _ext=".tar.gz"
        [ "$_os" = "windows" ] && _ext=".zip"
        _f="$DIST_DIR/msc-${VERSION}-${_os}-${_arch}${_ext}"
        if [ -f "$_f" ]; then
            echo "  $(ls -lh "$_f" | awk '{print $5, $NF}')"
        fi
    done

    if [ "$UPLOAD" = true ]; then
        echo ""
        upload_release
    fi
else
    echo "$failed of ${#TARGETS[@]} target(s) failed."
    exit 1
fi
