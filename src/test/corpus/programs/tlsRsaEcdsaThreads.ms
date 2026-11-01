// A TLS handshake and read on a worker thread while the main thread signs with RSA and ECDSA in a loop:
// both sides take the one PSA lock, so neither fails and nothing crashes.
//
// @stdout: tls: 12|sign: 40
// @exit: 0
// @skip-js: std/crypto/tls has only a C backend (index.cms over mbedTLS)
// @skip-raiser: std/crypto/tls has only a C backend and the Raiser VM cannot spawn processes
// @serial

import { tlsConnect, write, read, close } from "std/crypto/tls";
import { RsaPrivateKey, sign as signWithRsa, verify as verifyWithRsa } from "std/crypto/rsa";
import { EcPrivateKey, ecdsaSign, ecdsaVerify } from "std/crypto/ec";
import { argv } from "std/process";
import { spawn as spawnProcess, ChildStream } from "std/process/child";

function exchange(port: int32, ca: string): int32 {
	const r = tlsConnect("127.0.0.1", port, { caPath: ca });
	if (!r.ok) return 0;
	r.value.write("GET / HTTP/1.0\r\n\r\n");
	const head = r.value.read(64);
	r.value.close();
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

function tlsLoop(port: int32): int32 {
	let ok = 0;
	for (let i = 0; i < 12; i++) ok += exchange(port, "");
	return ok;
}

async function signLoop(rsaKey: RsaPrivateKey, ecKey: EcPrivateKey): Promise<int32> {
	let ok = 0;
	const rsaPublic = rsaKey.publicKey();
	const ecPublic = ecKey.publicKey();
	for (let i = 0; i < 20; i++) {
		const message = `message ${i}`;
		const r = await signWithRsa(rsaKey, message, "sha256");
		if (r.ok && await verifyWithRsa(rsaPublic, message, r.value, "sha256")) ok += 1;
		const e = await ecdsaSign(ecKey, message, "sha256");
		if (e.ok && await ecdsaVerify(ecPublic, message, e.value, "sha256")) ok += 1;
	}
	return ok;
}

async function mixed(port: int32): Promise<void> {
	const rsaKey = await RsaPrivateKey.generate(2048);
	const ecKey = await EcPrivateKey.generate("p256");
	if (!rsaKey.ok || !ecKey.ok) throw new Error("key generation failed");
	const rk = rsaKey.value;
	const ek = ecKey.value;
	const t = spawn(() => tlsLoop(port));
	const signOk = await signLoop(rk, ek);
	const tlsOk = await t;
	console.log(`tls: ${tlsOk}|sign: ${signOk}`);
}

if (argv.length > 1 && argv[1] == "mixed") {
	mixed(parseInt(argv[2]) as int32);
} else {
	const dir = `/tmp/msTlsRsaThreads-${Date.now()}`;
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
	const row = sh(`${env} "${self}" mixed ${port}`);
	server.value.kill();
	server.value.close();
	sh(`rm -rf ${dir}`);
	console.log(row);
}
