# Interop matrix of native tlsConnect against openssl s_server: every suite, group and key type the client offers,
# HelloRetryRequest, fragmented and padded records, chains, and refusals. Starts the servers, runs
# std/crypto/tls/interopLiveTest.ms with $B, stops the servers.
# Usage: B=<compiler> bash std/crypto/tls/test/interop.sh
set -u
D=$(mktemp -d /tmp/tlsInterop.XXXXXX)
openssl version
o() { openssl "$@" 2>/dev/null; }
V="-days 2"
ca() { # name subject [extra ext]
  o req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $D/$1.key -out $D/$1.pem -subj "$2" $V \
    -addext basicConstraints=critical,CA:TRUE${3:-} -addext keyUsage=critical,keyCertSign,cRLSign
}
leaf() { # name keyalg-args issuer ext-lines [validity]
  o req -new $2 -nodes -keyout $D/$1.key -out $D/$1.csr -subj /CN=localhost
  printf "subjectAltName=DNS:localhost\n$4" > $D/$1.cnf
  o x509 -req -in $D/$1.csr -CA $D/$3.pem -CAkey $D/$3.key -CAcreateserial -out $D/$1.pem -extfile $D/$1.cnf ${5:-$V}
}
ca ca /CN=interop-ca
ca other /CN=interop-other
ca fake /CN=interop-ca
EC256="-newkey ec -pkeyopt ec_paramgen_curve:prime256v1"
leaf p256 "$EC256" ca ""
leaf p384 "-newkey ec -pkeyopt ec_paramgen_curve:secp384r1" ca ""
leaf rsa "-newkey rsa:2048" ca ""
leaf ed "-newkey ed25519" ca ""
leaf forged "$EC256" fake ""
leaf client "$EC256" ca "extendedKeyUsage=clientAuth\n"
leaf expired "$EC256" ca "" "-not_before 20200101000000Z -not_after 20200102000000Z"
# ca -> inter -> chained ; ca -> zero (pathlen 0) -> sub -> deep
for n in inter zero sub; do o req -new $EC256 -nodes -keyout $D/$n.key -out $D/$n.csr -subj /CN=interop-$n; done
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n' > $D/ca.cnf
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign\n' > $D/zero.cnf
o x509 -req -in $D/inter.csr -CA $D/ca.pem -CAkey $D/ca.key -CAcreateserial -out $D/inter.pem -extfile $D/ca.cnf $V
o x509 -req -in $D/zero.csr -CA $D/ca.pem -CAkey $D/ca.key -CAcreateserial -out $D/zero.pem -extfile $D/zero.cnf $V
o x509 -req -in $D/sub.csr -CA $D/zero.pem -CAkey $D/zero.key -CAcreateserial -out $D/sub.pem -extfile $D/ca.cnf $V
leaf chained "$EC256" inter ""
leaf deep "$EC256" sub ""
cat $D/sub.pem $D/zero.pem > $D/deepChain.pem
for f in p256 p384 rsa ed forged client expired chained deep; do [ -s $D/$f.pem ] || echo "missing certificate $f"; done

P=$((20000 + RANDOM % 20000))
PIDS=""
CASES=""
# case <name> <host> <ca> <expect> -- <s_server args>
case_() {
  local name=$1 host=$2 cafile=$3 expect=$4; shift 5
  openssl s_server -accept 127.0.0.1:$P -www "$@" </dev/null >$D/$name.log 2>&1 &
  PIDS="$PIDS $!"
  CASES="$CASES$name|$host|$cafile|$P|$expect;"
  P=$((P + 1))
}
c() { echo "-cert $D/$1.pem -key $D/$1.key"; }
case_ t13-aes128-x25519-p256 localhost ca "ok 0304 1301 rekey alpn" -- -tls1_3 $(c p256) -ciphersuites TLS_AES_128_GCM_SHA256 -groups X25519 -alpn http/1.1
case_ t13-aes256-p256-rsa localhost ca "ok 0304 1302" -- -tls1_3 $(c rsa) -ciphersuites TLS_AES_256_GCM_SHA384 -groups P-256
case_ t13-chacha-ed25519 localhost ca "ok 0304 1303" -- -tls1_3 $(c ed) -ciphersuites TLS_CHACHA20_POLY1305_SHA256 -groups X25519
case_ t13-p384-cert localhost ca "ok 0304 *" -- -tls1_3 $(c p384)
case_ t13-rsa-pss-sha384 localhost ca "ok 0304 *" -- -tls1_3 $(c rsa) -sigalgs rsa_pss_rsae_sha384
case_ t13-rsa-pss-sha512 localhost ca "ok 0304 *" -- -tls1_3 $(c rsa) -sigalgs rsa_pss_rsae_sha512
case_ t13-hrr-p384 localhost ca "ok 0304 * hrr" -- -tls1_3 $(c p256) -groups P-384
case_ t13-hrr-cookie localhost ca "ok 0304 * hrr" -- -tls1_3 $(c p256) -stateless -groups P-384
case_ t13-fragmented localhost ca "ok 0304 *" -- -tls1_3 $(c rsa) -max_send_frag 512
case_ t13-padded localhost ca "ok 0304 *" -- -tls1_3 $(c p256) -record_padding 512
case_ t13-chain localhost ca "ok 0304 *" -- -tls1_3 $(c chained) -cert_chain $D/inter.pem
case_ t13-client-cert-asked localhost ca "ok 0304 *" -- -tls1_3 $(c p256) -verify 1
case_ t12-c02b-x25519 localhost ca "ok 0303 c02b" -- -tls1_2 $(c p256) -cipher ECDHE-ECDSA-AES128-GCM-SHA256 -groups X25519
case_ t12-c02c-p384 localhost ca "ok 0303 c02c" -- -tls1_2 $(c p384) -cipher ECDHE-ECDSA-AES256-GCM-SHA384 -groups P-384
case_ t12-c02f-pkcs1-sha256 localhost ca "ok 0303 c02f" -- -tls1_2 $(c rsa) -cipher ECDHE-RSA-AES128-GCM-SHA256 -sigalgs RSA+SHA256 -groups X25519
case_ t12-c030-pkcs1-sha384 localhost ca "ok 0303 c030" -- -tls1_2 $(c rsa) -cipher ECDHE-RSA-AES256-GCM-SHA384 -sigalgs RSA+SHA384 -groups P-256
case_ t12-c030-pkcs1-sha512 localhost ca "ok 0303 c030" -- -tls1_2 $(c rsa) -cipher ECDHE-RSA-AES256-GCM-SHA384 -sigalgs RSA+SHA512
case_ t12-c02f-pss localhost ca "ok 0303 c02f" -- -tls1_2 $(c rsa) -cipher ECDHE-RSA-AES128-GCM-SHA256 -sigalgs rsa_pss_rsae_sha256
case_ t12-cca8 localhost ca "ok 0303 cca8" -- -tls1_2 $(c rsa) -cipher ECDHE-RSA-CHACHA20-POLY1305
case_ t12-cca9 localhost ca "ok 0303 cca9" -- -tls1_2 $(c p256) -cipher ECDHE-ECDSA-CHACHA20-POLY1305
case_ t12-ecdsa-sha512-not-offered localhost ca "err handshake_failure" -- -tls1_2 $(c p256) -sigalgs ECDSA+SHA512
case_ t12-p384-group localhost ca "ok 0303 *" -- -tls1_2 $(c p256) -groups P-384
case_ t12-fragmented localhost ca "ok 0303 *" -- -tls1_2 $(c rsa) -max_send_frag 512
case_ t12-chain localhost ca "ok 0303 *" -- -tls1_2 $(c chained) -cert_chain $D/inter.pem
case_ no-common-suite-13 localhost ca "err handshake_failure" -- -tls1_3 $(c p256) -ciphersuites TLS_AES_128_CCM_SHA256
case_ no-common-suite-12 localhost ca "err handshake_failure" -- -tls1_2 $(c rsa) -cipher ECDHE-RSA-AES128-SHA256
case_ tls11-only localhost ca "err protocol_version" -- -tls1_1 $(c rsa) -cipher ALL:@SECLEVEL=0
case_ wrong-host 127.0.0.1 ca "err does not match" -- -tls1_3 $(c p256)
case_ untrusted-root localhost other "err not correctly signed" -- -tls1_3 $(c p256)
case_ forged-signature localhost ca "err not correctly signed" -- -tls1_3 $(c forged)
case_ expired localhost ca "err expired" -- -tls1_3 $(c expired)
case_ client-only-eku localhost ca "err KeyUsageMismatch" -- -tls1_3 $(c client)
case_ path-length localhost ca "err PathLengthExceeded" -- -tls1_2 $(c deep) -cert_chain $D/deepChain.pem
sleep 1
TLS_INTEROP_DIR=$D TLS_INTEROP_CASES="$CASES" "$B" test std/crypto/tls/interopLiveTest.ms --tests-in-dir 2>&1 \
  | grep -E "^interop|Tests|✓|✗|FAIL|assert|rror" | grep -v "^\s*|" | cut -c1-200
kill $PIDS 2>/dev/null
for f in $D/*.log; do grep -qiE "error|unknown option" $f && { echo "-- server $(basename $f .log):"; head -3 $f; }; done
exit 0
