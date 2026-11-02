// @stdout: binary sha256 02b82d4168ea1f7943df65fa7ff22891cc57a93b7c5e15e1b71a3f7ae43f3324
// @stdout: all bytes sha256 40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880
// @stdout: empty sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
// @stdout: text sha256 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
// @stdout: unsupported algorithm true
// @exit: 0
// @skip-js: std/crypto has no JS module

import { CryptoError, sha256, hash } from "std/crypto";

function must(result: Result<string, CryptoError>): string {
	if (!result.ok) { throw new Error(result.error.message); }
	return result.value;
}

const binary: Buffer = [0, 255, 195, 40, 0, 128, 10, 13, 127];
console.log("binary sha256", must(sha256(binary)));
const all: Buffer = [];
for (let i: int32 = 0; i < 256; i += 1) { all.push(i as uint8); }
console.log("all bytes sha256", must(sha256(all)));
const empty: Buffer = [];
console.log("empty sha256", must(sha256(empty)));
console.log("text sha256", must(sha256("abc")));
console.log("unsupported algorithm", !hash("not-a-hash", binary).ok);
