// A TlsConnection closes once however it ends: close twice, a drop without close and a use after close
// are clean, and a read or write after close returns the defined closed error instead of touching freed memory.
//
// @stdout: close twice: ok|read after close: empty "TLS connection is closed"|write after close: -1 "TLS connection is closed"|peerCert after close: empty|drop without close: 8 ok|live read: ok
// @exit: 0
// @skip-js: std/crypto/tls has only a C backend (index.cms over mbedTLS)
// @skip-raiser: std/crypto/tls has only a C backend and the Raiser VM cannot spawn processes
// @serial

import { tlsConnect, TlsConnection, read, write, close, peerCert } from "std/crypto/tls";
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

function open(port: int32, ca: string): TlsConnection {
	const r = tlsConnect("127.0.0.1", port, { caPath: ca });
	if (!r.ok) throw new Error(r.error.message);
	return r.value;
}

function dropped(port: int32, ca: string): boolean {
	const conn = open(port, ca);
	return conn.peerCert() != "";
}

if (argv.length > 1 && argv[1] == "life") {
	const port = parseInt(argv[2]) as int32;
	const ca = argv[3];
	const conn = open(port, ca);
	conn.close();
	conn.close();
	const rows: string[] = ["close twice: ok"];
	const got = conn.read(16);
	rows.push(`read after close: ${got.length == 0 ? "empty" : "data"} "${conn.lastError}"`);
	const wrote = conn.write("x");
	rows.push(`write after close: ${wrote} "${conn.lastError}"`);
	rows.push(`peerCert after close: ${conn.peerCert() == "" ? "empty" : "set"}`);
	let kept = 0;
	for (let i = 0; i < 8; i++) if (dropped(port, ca)) kept++;
	rows.push(`drop without close: ${kept} ok`);
	const live = open(port, ca);
	live.write("GET / HTTP/1.0\r\n\r\n");
	rows.push(`live read: ${live.read(64).length >= 8 && live.lastError == "" ? "ok" : "bad"}`);
	console.log(rows.join("|"));
} else {
	const dir = `/tmp/msTlsLifecycle-${Date.now()}`;
	const port = (30000 + Date.now() % 20000) as int32;
	sh(`set -e; mkdir -p ${dir}; cd ${dir}
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca.key -out ca.pem -subj /CN=ca -days 2
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout server.key -out server.csr -subj /CN=server
printf 'subjectAltName=IP:127.0.0.1\\n' > ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile ext.cnf`);

	const server = spawn("openssl", ["s_server", "-accept", `127.0.0.1:${port}`, "-cert", `${dir}/server.pem`, "-key", `${dir}/server.key`, "-quiet", "-www"]);
	if (!server.ok) throw new Error(`server spawn failed: ${server.error.message}`);
	server.value.wait(1500);

	const out = sh(`exec "$0" life ${port} ${dir}/ca.pem`, [argv[0]]);
	server.value.kill();
	server.value.close();
	sh(`rm -rf ${dir}`);
	console.log(out.trim());
}
