// The default CA chain is parsed once per process: two connects in one process and two connects from
// two threads at once all verify against it, and an explicit caPath keeps its own parse.
//
// @stdout: twice: 1 1|threads: 2|explicit then default: 1 1
// @exit: 0
// @skip-js: std/crypto/tls has only a C backend (index.cms over mbedTLS)
// @skip-raiser: std/crypto/tls has only a C backend and the Raiser VM cannot spawn processes
// @serial

import { tlsConnect, tlsWrite, tlsRead, tlsClose } from "std/crypto/tls";
import { argv } from "std/process";
import { spawn as spawnProcess, ChildStream } from "std/process/child";

function exchange(port: int32, ca: string): int32 {
	const r = tlsConnect("127.0.0.1", port, ca);
	if (!r.ok) return 0;
	tlsWrite(r.value, "GET / HTTP/1.0\r\n\r\n");
	const head = tlsRead(r.value, 64);
	tlsClose(r.value);
	return head.length >= 8 ? 1 : 0;
}

function sh(script: string): string {
	const r = spawnProcess("/bin/sh", ["-c", script]);
	if (!r.ok) throw new Error(`spawn failed: ${r.error.message}`);
	let text = "";
	for (let i = 0; i < 1000; i++) {
		const got = r.value.read(ChildStream.Stdout, 5000);
		if (!got.ok || got.value.ended) break;
		text += got.value.data;
	}
	r.value.close();
	return text.trim();
}

async function threads(port: int32): Promise<void> {
	const a = spawn(() => exchange(port, ""));
	const b = spawn(() => exchange(port, ""));
	console.log(`${(await a) + (await b)}`);
}

if (argv.length > 1 && argv[1] == "twice") {
	const port = parseInt(argv[2]) as int32;
	console.log(`${exchange(port, "")} ${exchange(port, "")}`);
} else if (argv.length > 1 && argv[1] == "threads") {
	threads(parseInt(argv[2]) as int32);
} else if (argv.length > 1 && argv[1] == "explicit") {
	const port = parseInt(argv[2]) as int32;
	console.log(`${exchange(port, argv[3])} ${exchange(port, "")}`);
} else {
	const dir = `/tmp/msTlsShared-${Date.now()}`;
	const port = (30000 + Date.now() % 20000) as int32;
	sh(`set -e; mkdir -p ${dir}; cd ${dir}
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout ca.key -out ca.pem -subj /CN=ca -days 2
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout server.key -out server.csr -subj /CN=server
printf 'subjectAltName=IP:127.0.0.1\\n' > ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 2 -extfile ext.cnf`);
	const server = spawnProcess("/bin/sh", ["-c", `exec openssl s_server -accept 127.0.0.1:${port} -cert ${dir}/server.pem -key ${dir}/server.key -quiet -www`]);
	if (!server.ok) throw new Error(`server spawn failed: ${server.error.message}`);
	server.value.wait(1500);
	const self = argv[0];
	const env = `SSL_CERT_FILE=${dir}/ca.pem`;
	const rows = [
		`twice: ${sh(`${env} "${self}" twice ${port}`)}`,
		`threads: ${sh(`${env} "${self}" threads ${port}`)}`,
		`explicit then default: ${sh(`${env} "${self}" explicit ${port} ${dir}/ca.pem`)}`,
	];
	server.value.kill();
	server.value.close();
	sh(`rm -rf ${dir}`);
	console.log(rows.join("|"));
}
