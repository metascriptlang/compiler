// The async hash functions complete inside the async function with the bytes their Sync form returns, on the C
// backend and on the Raiser (which the compiler's own sha256 call runs on), for every named hash and for digest()
// over every HashAlgorithm.
//
// @stdout: sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad true
// @stdout: sha384 cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7 true
// @stdout: sha512 ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f true
// @stdout: sha1 a9993e364706816aba3e25717850c26c9cd0d89d true
// @stdout: md5 900150983cd24fb0d6963f7d28e17f72 true
// @stdout: digest 11 algorithms, 11 same, 0 failed
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over runtime/crypto); there is no index.jms

import { Buffer } from "std/core/buffer";
import { CryptoError, HashAlgorithm, digest, digestSync, md5, md5Sync, sha1, sha1Sync, sha256, sha256Sync, sha384, sha384Sync, sha512, sha512Sync, toHex } from "std/crypto";

function line(name: string, viaAsync: Result<Buffer, CryptoError>, viaSync: Result<Buffer, CryptoError>): void {
	if (!viaAsync.ok || !viaSync.ok) {
		console.log(`${name} failed`);
		return;
	}
	console.log(`${name} ${toHex(viaAsync.value)} ${toHex(viaAsync.value) == toHex(viaSync.value)}`);
}

line("sha256", await sha256("abc"), sha256Sync("abc"));
line("sha384", await sha384("abc"), sha384Sync("abc"));
line("sha512", await sha512("abc"), sha512Sync("abc"));
line("sha1", await sha1("abc"), sha1Sync("abc"));
line("md5", await md5("abc"), md5Sync("abc"));

const algorithms: HashAlgorithm[] = [
	"sha256", "sha512", "sha384", "sha224", "sha1", "md5", "ripemd160",
	"sha3-224", "sha3-256", "sha3-384", "sha3-512",
];
let same = 0;
let failed = 0;
for (const algorithm of algorithms) {
	const viaAsync = await digest(algorithm, "abc");
	const viaSync = digestSync(algorithm, "abc");
	if (!viaAsync.ok || !viaSync.ok) {
		failed++;
		continue;
	}
	if (toHex(viaAsync.value) == toHex(viaSync.value)) same++;
}
console.log(`digest ${algorithms.length} algorithms, ${same} same, ${failed} failed`);
