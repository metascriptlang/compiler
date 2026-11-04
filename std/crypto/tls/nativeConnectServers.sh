# Generates TLS_NATIVE_DIR certs and starts three s_servers (1.3, 1.3 expired, 1.2); prints env lines.
set -e
D=$(mktemp -d /tmp/tlsNative.XXXXXX)
openssl version >&2
o() { openssl "$@" 2>/dev/null; }
for n in ca other; do
  o req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $D/$n.key -out $D/$n.pem -subj /CN=$n -days 2 -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
done
o req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $D/leaf.key -out $D/leaf.csr -subj /CN=localhost
printf 'subjectAltName=DNS:localhost\n' > $D/ext.cnf
o x509 -req -in $D/leaf.csr -CA $D/ca.pem -CAkey $D/ca.key -CAcreateserial -out $D/leaf.pem -days 2 -extfile $D/ext.cnf
if ! o x509 -req -in $D/leaf.csr -CA $D/ca.pem -CAkey $D/ca.key -CAcreateserial -out $D/old.pem -not_before 20200101000000Z -not_after 20200102000000Z -extfile $D/ext.cnf; then
  echo "x509 -not_after unsupported; trying ca -startdate" >&2
  mkdir -p $D/db && : > $D/db/index && echo 01 > $D/db/serial
  printf '[ca]\ndefault_ca=c\n[c]\ndir=%s/db\ndatabase=$dir/index\nserial=$dir/serial\nnew_certs_dir=$dir\ndefault_md=sha256\npolicy=p\ncopy_extensions=none\n[p]\ncommonName=supplied\n[e]\nsubjectAltName=DNS:localhost\n' $D > $D/ca.cnf
  openssl ca -batch -config $D/ca.cnf -cert $D/ca.pem -keyfile $D/ca.key -in $D/leaf.csr -out $D/old.pem -startdate 20200101000000Z -enddate 20200102000000Z -extensions e >&2
fi
P=$((30000 + RANDOM % 20000)); Q=$((P + 1)); R=$((P + 2))
openssl s_server -accept 127.0.0.1:$P -cert $D/leaf.pem -key $D/leaf.key -tls1_3 -www -quiet >/dev/null 2>&1 &
openssl s_server -accept 127.0.0.1:$Q -cert $D/old.pem -key $D/leaf.key -tls1_3 -www -quiet >/dev/null 2>&1 &
openssl s_server -accept 127.0.0.1:$R -cert $D/leaf.pem -key $D/leaf.key -tls1_2 -www -quiet >/dev/null 2>&1 &
sleep 1
echo "export TLS_NATIVE_DIR=$D TLS_NATIVE_PORT=$P TLS_NATIVE_EXPIRED_PORT=$Q TLS_NATIVE_TLS12_PORT=$R"
