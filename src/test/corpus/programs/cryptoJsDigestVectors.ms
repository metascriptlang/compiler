// Hash vectors from FIPS 180 and RFC 1321 agree on the C backend (mbedTLS) and on JS (WebCrypto async, the portable
// code for Sync, md5 and sha224): each digest is checked in its Sync and async form, "abc" reproduces the card's
// `sha256("abc")` digest, and a million "a" through createHash in uneven chunks gives the NIST value.
//
// @stdout: sha256 abc true true
// @stdout: sha256 empty true true
// @stdout: sha256 two-block true true
// @stdout: sha384 abc true true
// @stdout: sha512 abc true true
// @stdout: sha512 two-block true true
// @stdout: sha224 abc true true
// @stdout: sha1 abc true true
// @stdout: sha1 two-block true true
// @stdout: md5 empty true true
// @stdout: md5 abc true true
// @stdout: md5 digits true true
// @stdout: million a true
// @stdout: bytes input true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs
import { HashAlgorithm, createHash, digest, digestSync, toHex } from "std/crypto";

async function check(label: string, algorithm: HashAlgorithm, input: string, expected: string): Promise<void> {
	const viaSync = digestSync(algorithm, input);
	const viaAsync = await digest(algorithm, input);
	const syncOk = viaSync.ok && toHex(viaSync.value) == expected;
	const asyncOk = viaAsync.ok && toHex(viaAsync.value) == expected;
	console.log(label, syncOk, asyncOk);
}

const twoBlock = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
const longBlock = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";

await check("sha256 abc", "sha256", "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
await check("sha256 empty", "sha256", "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
await check("sha256 two-block", "sha256", twoBlock, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
await check("sha384 abc", "sha384", "abc", "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7");
await check("sha512 abc", "sha512", "abc", "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
await check("sha512 two-block", "sha512", longBlock, "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909");
await check("sha224 abc", "sha224", "abc", "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7");
await check("sha1 abc", "sha1", "abc", "a9993e364706816aba3e25717850c26c9cd0d89d");
await check("sha1 two-block", "sha1", twoBlock, "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
await check("md5 empty", "md5", "", "d41d8cd98f00b204e9800998ecf8427e");
await check("md5 abc", "md5", "abc", "900150983cd24fb0d6963f7d28e17f72");
await check("md5 digits", "md5", "12345678901234567890123456789012345678901234567890123456789012345678901234567890", "57edf4a22be3c955ac49da2e2107b67a");

const hasher = createHash("sha256");
const chunk = new Array<uint8>(1000);
for (let i = 0; i < 1000; i++) chunk[i] = 97;
const odd = new Array<uint8>(7);
for (let i = 0; i < 7; i++) odd[i] = 97;
for (let i = 0; i < 500; i++) hasher.update(chunk);
for (let i = 0; i < 71428; i++) hasher.update(odd);
for (let i = 0; i < 4; i++) hasher.update("a");
console.log("million a", toHex(hasher.digest()) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");

const fromBytes = digestSync("sha256", [97, 98, 99]);
console.log("bytes input", fromBytes.ok && toHex(fromBytes.value) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
