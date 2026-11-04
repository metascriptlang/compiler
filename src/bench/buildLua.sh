#!/usr/bin/env bash
# usage: src/bench/buildLua.sh <dir>
# Builds <dir>/luajit (LuaJIT v2.1 at LUAJIT_COMMIT) and <dir>/lua54 (Lua LUA_VERSION, checked by LUA_SHA256) from
# source, once each; a later call reuses them. A build that fails leaves its binary out and names its log.
set -uo pipefail

DIR=${1:?usage: src/bench/buildLua.sh <dir>}
LUAJIT_COMMIT=ea9eb7edb5eac4a9d175d74523db34fac0fa5180
LUA_VERSION=5.4.7
LUA_SHA256=9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30
mkdir -p "$DIR/src"
[ "$(uname -s)" = Darwin ] && export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-11.0}

if [ ! -x "$DIR/luajit" ]; then
	src=$DIR/src/LuaJIT
	rm -rf "$src" && mkdir -p "$src"
	{
		git -C "$src" init -q &&
			git -C "$src" fetch -q --depth 1 https://github.com/LuaJIT/LuaJIT "$LUAJIT_COMMIT" &&
			git -C "$src" checkout -q FETCH_HEAD &&
			make -C "$src" -j8
	} >"$DIR/luajit-build.log" 2>&1 && cp "$src/src/luajit" "$DIR/luajit" ||
		echo "buildLua: LuaJIT did not build, see $DIR/luajit-build.log" >&2
fi

if [ ! -x "$DIR/lua54" ]; then
	tgz=$DIR/src/lua-$LUA_VERSION.tar.gz
	{
		curl -fsSLo "$tgz" "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" &&
			[ "$( (sha256sum "$tgz" 2>/dev/null || shasum -a 256 "$tgz") | cut -d' ' -f1)" = "$LUA_SHA256" ] &&
			tar -xzf "$tgz" -C "$DIR/src" &&
			make -C "$DIR/src/lua-$LUA_VERSION" posix
	} >"$DIR/lua54-build.log" 2>&1 && cp "$DIR/src/lua-$LUA_VERSION/src/lua" "$DIR/lua54" ||
		echo "buildLua: Lua $LUA_VERSION did not build, see $DIR/lua54-build.log" >&2
fi
exit 0
