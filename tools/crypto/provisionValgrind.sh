#!/usr/bin/env bash
# usage: provisionValgrind.sh <destDir>   (destDir/<package>/ holds each extracted .deb; nothing outside destDir is written)
set -euo pipefail
dest=${1:?usage: provisionValgrind.sh <destDir>}
pins=$(cd "$(dirname "$0")" && pwd)/pins.tsv
mkdir -p "$dest/download"
dest=$(cd "$dest" && pwd)
while IFS=$'\t' read -r name version url sha512 licence; do
	file=$dest/download/${url##*/}
	if [ ! -f "$file" ]; then
		curl -fsSL --retry 3 -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	echo "$sha512  $file" | sha512sum --check --strict -
	if [ ! -d "$dest/$name" ]; then
		mkdir "$dest/$name.partial"
		dpkg-deb -x "$file" "$dest/$name.partial"
		mv "$dest/$name.partial" "$dest/$name"
	fi
	echo "provisioned $name $version ($licence) from $url"
done < "$pins"
interp=$(readelf -l /bin/true | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')
buildId=$(readelf -n "$interp" | sed -n 's/.*Build ID: //p')
debugFile=$dest/libc6-dbg/usr/lib/debug/.build-id/${buildId:0:2}/${buildId:2}.debug
[ -f "$debugFile" ] || { echo "libc6-dbg has no debug file for the loader $interp (build id $buildId)" >&2; exit 1; }
objdir=$(dirname "$(readlink -f "$interp")")
mkdir -p "$dest/debugroot$objdir"
ln -sf "$debugFile" "$dest/debugroot$objdir/${buildId:2}.debug"
echo "loader $interp (build id $buildId) debuginfo linked under $dest/debugroot"
test -x "$dest/valgrind/usr/bin/valgrind"
test -f "$dest/valgrind/usr/include/valgrind/memcheck.h"
VALGRIND_LIB="$dest/valgrind/usr/libexec/valgrind" "$dest/valgrind/usr/bin/valgrind" --version
