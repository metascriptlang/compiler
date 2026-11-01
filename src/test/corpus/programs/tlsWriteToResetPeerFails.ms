// A TLS write to a peer that has gone returns -1 and the process keeps running, instead of dying
// of SIGPIPE: once while a bulk write is in flight, once after a first write succeeded and a read
// saw the peer vanish.
//
// @stdout: during bulk write: exit 0 signal 0 write -1|after first write and read: exit 0 signal 0 write -1
// @exit: 0
// @skip-js: std/crypto/tls has only a C backend (index.cms over mbedTLS)
// @skip-raiser: std/crypto/tls has only a C backend and the Raiser VM cannot spawn processes
// @serial

import { tlsConnect, read, write } from "std/crypto/tls";
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

function readUntil(child: ChildProcess, marker: string): void {
	let text = "";
	while (!text.includes(marker)) {
		const got = child.read(ChildStream.Stdout, 10000);
		if (!got.ok || got.value.ended) throw new Error(`child ended before ${marker}: ${text}`);
		text += got.value.data;
	}
}

function sh(script: string): void {
	const r = spawn("/bin/sh", ["-c", script]);
	if (!r.ok) throw new Error(`spawn failed: ${r.error.message}`);
	readAll(r.value);
	r.value.close();
}

if (argv.length > 1 && argv[1] == "write") {
	const r = tlsConnect("127.0.0.1", parseInt(argv[2]) as int32, { caPath: argv[3] });
	if (!r.ok) throw new Error(r.error.message);
	const ctx = r.value;
	let chunk = "";
	for (let i = 0; i < 65536; i++) chunk += "x";
	if (argv[4] == "during") {
		console.log("writing");
		while (ctx.write(chunk) > 0) {}
	} else {
		ctx.write("first");
		console.log("connected");
		ctx.read(16);
		let written = 1;
		while (written > 0) written = ctx.write(chunk);
	}
	console.log("write -1");
} else {
	const dir = `/tmp/msTlsWriteReset-${Date.now()}`;
	const port = 30000 + Date.now() % 20000;
	sh(`set -e; mkdir -p ${dir}; cd ${dir}
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca.key -out ca.pem -subj /CN=ca -days 2
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout server.key -out server.csr -subj /CN=server
printf 'subjectAltName=IP:127.0.0.1\n' > ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile ext.cnf`);

	function scenario(label: string, mode: string, marker: string): string {
		const server = spawn("openssl", ["s_server", "-accept", `${port + (mode == "during" ? 0 : 1)}`, "-cert", `${dir}/server.pem`, "-key", `${dir}/server.key`, "-quiet"]);
		if (!server.ok) throw new Error(`server spawn failed: ${server.error.message}`);
		server.value.wait(1500);
		const portOf = port + (mode == "during" ? 0 : 1);
		const client = spawn(argv[0], ["write", `${portOf}`, `${dir}/ca.pem`, mode]);
		if (!client.ok) throw new Error(`client spawn failed: ${client.error.message}`);
		readUntil(client.value, marker);
		client.value.wait(300);
		server.value.kill();
		server.value.close();
		const rest = readAll(client.value);
		const status = client.value.wait(10000);
		client.value.close();
		if (!status.ok) return `${label}: no exit: ${status.error.message}`;
		return `${label}: exit ${status.value.code} signal ${status.value.signal} ${rest.trim()}`;
	}

	const rows = [
		scenario("during bulk write", "during", "writing"),
		scenario("after first write and read", "after", "connected"),
	];
	sh(`rm -rf ${dir}`);
	console.log(rows.join("|"));
}
