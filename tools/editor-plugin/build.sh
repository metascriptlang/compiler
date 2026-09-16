#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NVIM_DIR="$SCRIPT_DIR/metascript.nvim"
TS_DIR="$NVIM_DIR/tree-sitter"
TS_SRC="$TS_DIR/src"
SOURCE="$NVIM_DIR/queries/metascript/highlights.scm"

INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

if [ ! -f "$SOURCE" ]; then
  echo "ERROR: Source not found: $SOURCE"
  exit 1
fi

copy() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cp "$SOURCE" "$dest"
  echo "  copied -> $dest"
}

# 1. Regenerate parser from grammar.js
if command -v tree-sitter &>/dev/null; then
  echo "Regenerating parser from grammar.js..."
  (cd "$TS_DIR" && tree-sitter generate 2>&1 | grep -v "^Warning:" || true)
  echo "  done"
else
  echo "WARNING: tree-sitter CLI not found, skipping parser regeneration"
fi
echo ""

# 2. Build bundled metascript.so (plugin copies this on startup)
echo "Building bundled parser..."
BUNDLED_SO="$TS_DIR/metascript.so"
SCANNER="$TS_SRC/scanner.c"
SCANNER_FLAG=""
if [ -f "$SCANNER" ]; then
  SCANNER_FLAG="$SCANNER"
fi
cc -shared -fPIC -O2 \
  -I "$TS_SRC" \
  "$TS_SRC/parser.c" \
  $SCANNER_FLAG \
  -o "$BUNDLED_SO"
echo "  compiled -> $BUNDLED_SO"
echo ""

# 3. Sync highlights.scm to all repo locations
echo "Syncing highlights.scm:"
copy "$TS_DIR/queries/highlights.scm"
copy "$SCRIPT_DIR/zed/languages/metascript/highlights.scm"
copy "$SCRIPT_DIR/zed/grammars/metascript/queries/highlights.scm"
echo ""

# 4. Sync Zed queries with adaptations (highlights, indents, injections)
echo "Syncing Zed queries (adapted)..."
ZED_LANG="$SCRIPT_DIR/zed/languages/metascript"
ZED_GQ="$SCRIPT_DIR/zed/grammars/metascript/queries"
mkdir -p "$ZED_LANG" "$ZED_GQ"
for file in highlights.scm indents.scm injections.scm; do
  src="$NVIM_DIR/queries/metascript/$file"
  if [ ! -f "$src" ]; then
    src="$TS_DIR/queries/$file"
  fi
  if [ -f "$src" ]; then
    # Adapt Neovim predicates for Zed
    sed -e 's/#lua-match?/#match?/g' \
        -e 's/ @spell//g' \
        -e 's/@variable\.parameter/@parameter/g' \
        -e 's/@variable\.builtin/@variable.special/g' \
        -e 's/@constant\.builtin/@constant.special/g' \
        -e 's/@type\.builtin/@type/g' \
        -e 's/@function\.builtin/@function.special/g' \
        -e 's/@function\.method/@function/g' \
        -e 's/@punctuation\.special/@punctuation.bracket/g' \
        -e 's/@keyword\.directive/@keyword.control/g' \
        -e 's/@function\.macro/@function/g' \
        "$src" > "$ZED_LANG/$file"
    cp "$ZED_LANG/$file" "$ZED_GQ/$file"
    echo "  $file -> zed/"
  fi
done
echo ""

# 5. Sync VS Code TextMate grammar (source of truth is in vscode/)
echo "VS Code: syntaxes/metascript.tmLanguage.json is edited in-place (no sync needed)"
echo ""

# 5b. Sync IntelliJ TextMate bundle from VSCode source (one-way mirror).
# vscode/ is the source of truth for grammar + language-configuration.
# Icon is NOT synced — JetBrains IDEs require 16x16 file-type icons (with
# rounded corners for visual consistency with the platform UI), while VSCode
# uses 128x128 square icons for tree-view. jetbrains/.../icons/metascript.png
# is pre-resized + corner-rounded, checked into git. Regenerate with:
#   sips -z 16 16 vscode/icons/metascript.png --out /tmp/ms-16.png
#   sips -z 32 32 vscode/icons/metascript.png --out /tmp/ms-32.png
#   magick /tmp/ms-16.png -alpha set \
#     \( +clone -alpha transparent -fill white -draw 'roundrectangle 0,0 15,15 3,3' \) \
#     -channel A -compose dstin -composite +channel \
#     PNG32:jetbrains/src/main/resources/icons/metascript.png
#   magick /tmp/ms-32.png -alpha set \
#     \( +clone -alpha transparent -fill white -draw 'roundrectangle 0,0 31,31 6,6' \) \
#     -channel A -compose dstin -composite +channel \
#     PNG32:jetbrains/src/main/resources/icons/metascript@2x.png
# Does NOT run `gradle buildPlugin` (heavy, separate concern — see
# tools/editor-plugin/jetbrains/README.md for build instructions).
echo "Syncing JetBrains TextMate bundle..."
JB_TM_DIR="$SCRIPT_DIR/jetbrains/src/main/resources/textmate/metascript"
mkdir -p "$JB_TM_DIR/syntaxes"
cp "$SCRIPT_DIR/vscode/syntaxes/metascript.tmLanguage.json" "$JB_TM_DIR/syntaxes/metascript.tmLanguage.json"
cp "$SCRIPT_DIR/vscode/language-configuration.json"          "$JB_TM_DIR/language-configuration.json"
echo "  grammar     -> jetbrains/.../textmate/metascript/syntaxes/"
echo "  langConfig  -> jetbrains/.../textmate/metascript/"
echo ""

# 6. Install to Neovim (--install flag)
if [ "$INSTALL" = true ]; then
  echo "Installing to Neovim:"
  PARSER_OUT="$HOME/.local/share/nvim/lazy/nvim-treesitter/parser/metascript.so"
  mkdir -p "$(dirname "$PARSER_OUT")"
  cp "$BUNDLED_SO" "$PARSER_OUT"
  echo "  parser -> $PARSER_OUT"

  QUERY_OUT="$HOME/.local/share/nvim/lazy/nvim-treesitter/queries/metascript/highlights.scm"
  mkdir -p "$(dirname "$QUERY_OUT")"
  cp "$SOURCE" "$QUERY_OUT"
  echo "  highlights -> $QUERY_OUT"

  AFTER_OUT="$HOME/nerdtools/nvim/after/queries/metascript/highlights.scm"
  mkdir -p "$(dirname "$AFTER_OUT")"
  cp "$SOURCE" "$AFTER_OUT"
  echo "  highlights -> $AFTER_OUT"
fi

echo ""
echo "Done."
