// std/crypto/tls verifies every certificate: a missing CA source or a CA that does not sign the server
// fails the connect with an error that names the cause, and only the signing CA connects.
//
// @stdout: env missing file: no-ca|env empty dir: no-ca|explicit unrelated CA: verify|env unrelated CA: verify|explicit signing CA: connected|env signing CA: connected
// @exit: 0
// @skip-js: std/crypto/tls has only a C backend (index.cms over mbedTLS)
// @skip-raiser: std/crypto/tls has only a C backend and the Raiser VM cannot spawn processes
// @serial

import { tlsConnect, close } from "std/crypto/tls";
import { argv } from "std/process";
import { spawn, ChildProcess, ChildStream } from "std/process/child";

function readAll(child: ChildProcess): string {
	let text = "";
	for (let i = 0; i < 1000; i++) {
		const got = child.read(ChildStream.Stdout, 5000);
		if (!got.ok || got.value.ended) return text;
		text += got.value.data;
	}
	return text;
}

function sh(script: string, args: string[] = []): string {
	const r = spawn("/bin/sh", ["-c", script, ...args]);
	if (!r.ok) throw new Error(`spawn failed: ${r.error.message}`);
	const out = readAll(r.value);
	r.value.close();
	return out;
}

if (argv.length > 1 && argv[1] == "connect") {
	const ca = argv[3] == "-" ? "" : argv[3];
	const r = tlsConnect("127.0.0.1", parseInt(argv[2]) as int32, { caPath: ca });
	if (r.ok) {
		r.value.close();
		console.log("connected");
	} else {
		console.log(r.error.message);
	}
} else {
	const dir = `/tmp/msTlsFailsClosed-${Date.now()}`;
	const port = 30000 + Date.now() % 20000;
	sh(`set -e; mkdir -p ${dir}/empty; cd ${dir}
for n in ca other; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout $n.key -out $n.pem -subj /CN=$n -days 2
done
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout server.key -out server.csr -subj /CN=server
printf 'subjectAltName=IP:127.0.0.1\n' > ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile ext.cnf`);

	const server = spawn("openssl", ["s_server", "-accept", `${port}`, "-cert", `${dir}/server.pem`, "-key", `${dir}/server.key`, "-quiet"]);
	if (!server.ok) throw new Error(`server spawn failed: ${server.error.message}`);

	const self = argv[0];
	function connect(env: string, ca: string): string {
		const script = `unset SSL_CERT_FILE SSL_CERT_DIR; ${env} exec "$0" connect ${port} ${ca}`;
		const out = sh(script, [self]).trim();
		if (out == "connected") return "connected";
		if (out.includes("no CA certificates found")) return "no-ca";
		if (out.includes("certificate verification failed")) return "verify";
		return `other: ${out}`;
	}

	let ready = false;
	for (let i = 0; i < 50 && !ready; i++) {
		ready = connect("", `${dir}/ca.pem`) == "connected";
		if (!ready) server.value.wait(100);
	}

	const rows = [
		`env missing file: ${connect(`SSL_CERT_FILE=${dir}/missing.pem`, "-")}`,
		`env empty dir: ${connect(`SSL_CERT_DIR=${dir}/empty`, "-")}`,
		`explicit unrelated CA: ${connect("", `${dir}/other.pem`)}`,
		`env unrelated CA: ${connect(`SSL_CERT_FILE=${dir}/other.pem`, "-")}`,
		`explicit signing CA: ${connect("", `${dir}/ca.pem`)}`,
		`env signing CA: ${connect(`SSL_CERT_FILE=${dir}/ca.pem`, "-")}`,
	];
	server.value.kill();
	server.value.close();
	sh(`rm -rf ${dir}`);
	console.log(rows.join("|"));
}
