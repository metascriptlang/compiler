// An https fetch honours its timeout against a server that accepts and never answers, reaches an
// IPv4-only server through `localhost`, tells a close_notify end of body from a cut connection, and
// tlsWrite and tlsConnect refuse the cases the transport used to swallow.
//
// @stdout: timeout 1000: Timeout in range|timeout 2500: Timeout in range|localhost ipv4-only: 200 clean-close|empty write: 0|long caPath: CA path is longer than 511 bytes|cut no length: Reset closed without close_notify|cut short length: Reset closed without close_notify
// @exit: 0
// @skip-js: std/crypto/tls has only a C backend (index.cms over mbedTLS)
// @skip-raiser: std/crypto/tls has only a C backend and the Raiser VM cannot spawn processes
// @serial

import { tlsConnect, tlsWrite, tlsClose } from "std/crypto/tls";
import { fetch, HttpErrorKind } from "std/core/fetch";
import { createSocket, bind, listen, accept, recv } from "std/net";
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

function sh(script: string): void {
	const r = spawn("/bin/sh", ["-c", script], { mergeStderr: true });
	if (!r.ok) throw new Error(`spawn failed: ${r.error.message}`);
	readAll(r.value);
	r.value.close();
}

if (argv.length > 1 && argv[1] == "hold") {
	const fd = createSocket();
	bind(fd, "127.0.0.1", parseInt(argv[2]) as int32);
	listen(fd, 4);
	const client = accept(fd);
	while (recv(client, 4096).length > 0) {}
} else if (argv.length > 1 && argv[1] == "fetch") {
	const started = Date.now();
	const r = fetch(argv[2], { method: "GET", body: "", timeout: parseInt(argv[3]) as int32, maxRedirects: 0 });
	const elapsed = (Date.now() - started) as number;
	if (r.ok) {
		console.log(`${r.value.status} ${r.value.bytes.length > 0 ? "clean-close" : "empty"}`);
	} else if (argv[4] == "time") {
		const limit = parseInt(argv[3]) as int32;
		const kind = r.error.kind == HttpErrorKind.Timeout ? "Timeout" : `other ${r.error.message}`;
		console.log(`${kind} ${elapsed >= limit - 200 && elapsed <= limit + 1500 ? "in range" : `out of range ${elapsed}`}`);
	} else {
		const kind = r.error.kind == HttpErrorKind.ConnectionReset ? "Reset" : `other ${r.error.kind}`;
		console.log(`${kind} ${r.error.message.includes("closed without close_notify") ? "closed without close_notify" : r.error.message}`);
	}
} else if (argv.length > 1 && argv[1] == "write0") {
	const r = tlsConnect("127.0.0.1", parseInt(argv[2]) as int32, argv[3]);
	if (!r.ok) throw new Error(r.error.message);
	console.log(`${tlsWrite(r.value, "")}`);
	tlsClose(r.value);
} else if (argv.length > 1 && argv[1] == "longca") {
	let ca = "/";
	for (let i = 0; i < 600; i++) ca += "a";
	const r = tlsConnect("127.0.0.1", parseInt(argv[2]) as int32, ca);
	console.log(r.ok ? "connected" : r.error.message.includes("longer than 511") ? "CA path is longer than 511 bytes" : r.error.message.slice(0, 60));
} else {
	const dir = `/tmp/msTlsTransport-${Date.now()}`;
	const port = (30000 + Date.now() % 20000) as int32;
	sh(`set -e; mkdir -p ${dir}; cd ${dir}
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca.key -out ca.pem -subj /CN=ca -days 2
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout server.key -out server.csr -subj /CN=server
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\\n' > ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile ext.cnf`);

	const self = argv[0];

	// A client that outlives its wait is killed and reported as hung.
	function client(args: string, waitMs: int32): string {
		const c = spawn("/bin/sh", ["-c", `SSL_CERT_FILE=${dir}/ca.pem exec "$0" ${args}`, self], { mergeStderr: true });
		if (!c.ok) throw new Error(`client spawn failed: ${c.error.message}`);
		const status = c.value.wait(waitMs);
		if (!status.ok) {
			c.value.kill();
			c.value.close();
			return "hung";
		}
		const out = readAll(c.value).trim();
		c.value.close();
		return out;
	}

	function holdScenario(timeoutMs: int32, p: int32): string {
		const holder = spawn(self, ["hold", `${p}`], { mergeStderr: true });
		if (!holder.ok) throw new Error(`holder spawn failed: ${holder.error.message}`);
		holder.value.wait(500);
		const out = client(`fetch https://127.0.0.1:${p}/ ${timeoutMs} time`, timeoutMs + 6000);
		holder.value.kill();
		holder.value.close();
		return `timeout ${timeoutMs}: ${out}`;
	}

	function tlsServer(p: int32, www: boolean, reply: string): ChildProcess {
		const common = `-accept 127.0.0.1:${p} -cert ${dir}/server.pem -key ${dir}/server.key -quiet`;
		const script = www
			? `exec openssl s_server ${common} -www`
			: `cd ${dir}; rm -f f${p}; mkfifo f${p}; { printf '${reply}'; sleep 25; } > f${p} & exec openssl s_server ${common} < f${p}`;
		const s = spawn("/bin/sh", ["-c", script], { mergeStderr: true });
		if (!s.ok) throw new Error(`server spawn failed: ${s.error.message}`);
		s.value.wait(1500);
		return s.value;
	}

	function stop(s: ChildProcess): void {
		s.kill();
		s.close();
	}

	function cutScenario(label: string, p: int32, reply: string): string {
		const server = tlsServer(p, false, reply);
		const c = spawn("/bin/sh", ["-c", `SSL_CERT_FILE=${dir}/ca.pem exec "$0" fetch https://localhost:${p}/ 20000 cut`, self], { mergeStderr: true });
		if (!c.ok) throw new Error(`client spawn failed: ${c.error.message}`);
		c.value.wait(1500);
		stop(server);
		const status = c.value.wait(8000);
		if (!status.ok) {
			c.value.kill();
			c.value.close();
			return `${label}: hung`;
		}
		const out = readAll(c.value).trim();
		c.value.close();
		return `${label}: ${out}`;
	}

	const rows: string[] = [];
	rows.push(holdScenario(1000, port));
	rows.push(holdScenario(2500, port + 1));

	const www = tlsServer(port + 2, true, "");
	rows.push(`localhost ipv4-only: ${client(`fetch https://localhost:${port + 2}/ 10000 clean`, 15000)}`);
	rows.push(`empty write: ${client(`write0 ${port + 2} ${dir}/ca.pem`, 15000)}`);
	rows.push(`long caPath: ${client(`longca ${port + 2}`, 15000)}`);
	stop(www);

	rows.push(cutScenario("cut no length", port + 3, "HTTP/1.1 200 OK\\r\\nConnection: close\\r\\n\\r\\npartial"));
	rows.push(cutScenario("cut short length", port + 4, "HTTP/1.1 200 OK\\r\\nContent-Length: 100\\r\\nConnection: close\\r\\n\\r\\npartial"));

	sh(`rm -rf ${dir}`);
	console.log(rows.join("|"));
}
