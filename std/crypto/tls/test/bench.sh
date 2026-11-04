# Handshake + 1 MiB GET, native .ms tlsConnect vs the public mbedTLS tlsConnect, against local openssl s_server -WWW.
# Usage: B=<compiler> bash std/crypto/tls/test/bench.sh   (builds std/crypto/tls/tlsBench.ms with --danger)
set -u
D=$(mktemp -d /tmp/tlsBench.XXXXXX)
o() { openssl "$@" 2>/dev/null; }
o req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $D/ca.key -out $D/ca.pem -subj /CN=bench-ca -days 2 \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign
o req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $D/leaf.key -out $D/leaf.csr -subj /CN=localhost
printf 'subjectAltName=DNS:localhost\n' > $D/leaf.cnf
o x509 -req -in $D/leaf.csr -CA $D/ca.pem -CAkey $D/ca.key -CAcreateserial -out $D/leaf.pem -extfile $D/leaf.cnf -days 2
head -c 1048576 /dev/urandom > $D/payload
"$B" build std/crypto/tls/tlsBench.ms --danger --output=out/tlsBench > $D/build.log 2>&1 || { tail -20 $D/build.log; exit 1; }
P=$((20000 + RANDOM % 20000))
PIDS=""
PORTS=""
srv() { # name args
  local name=$1; shift
  (cd $D && exec openssl s_server -accept 127.0.0.1:$P -WWW -cert $D/leaf.pem -key $D/leaf.key "$@" </dev/null >$D/$name.log 2>&1) &
  PIDS="$PIDS $!"
  PORTS="$PORTS${PORTS:+,}$name=$P"
  P=$((P + 1))
}
srv tls13-aes128gcm-x25519 -tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256 -groups X25519
srv tls13-chacha20-x25519 -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -groups X25519
srv tls12-ecdsa-aes128gcm-p256 -tls1_2 -cipher ECDHE-ECDSA-AES128-GCM-SHA256 -groups P-256
sleep 1
TLS_BENCH_CA=$D/ca.pem TLS_BENCH_PORTS=$PORTS out/tlsBench
kill $PIDS 2>/dev/null
exit 0
