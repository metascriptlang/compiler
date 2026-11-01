#!/usr/bin/env bash
set -euo pipefail
dest=${1:?usage: provisionOracles.sh <destDir>}
pins=$(cd "$(dirname "$0")" && pwd)/oraclePins.tsv
mkdir -p "$dest/download"
dest=$(cd "$dest" && pwd)
while IFS=$'\t' read -r name version url sha512 licence; do
	file=$dest/download/${url##*/}
	if [ ! -f "$file" ]; then
		curl -fsSL --retry 3 --max-time 120 -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	echo "$sha512  $file" | sha512sum --check --strict -
	if [ ! -d "$dest/$name" ]; then
		rm -rf "$dest/$name.partial"
		mkdir "$dest/$name.partial"
		dpkg-deb -x "$file" "$dest/$name.partial"
		mv "$dest/$name.partial" "$dest/$name"
	fi
	echo "provisioned $name $version ($licence) from $url"
done < "$pins"
lib=usr/lib/x86_64-linux-gnu
for f in libssl-dev/$lib/libcrypto.a libsodium-dev/$lib/libsodium.a libmbedtls-dev/$lib/libmbedcrypto.a \
	libssl-dev/usr/include/openssl/evp.h libsodium-dev/usr/include/sodium.h libmbedtls-dev/usr/include/mbedtls/ecp.h; do
	test -f "$dest/$f" || { echo "provisionOracles: pinned package lacks $f" >&2; exit 1; }
done
