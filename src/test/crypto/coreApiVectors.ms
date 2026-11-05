import {
	init, cleanup, digest, hmac, toHex,
	md5, md5Sync, sha1, sha1Sync, sha256, sha256Sync,
	sha384, sha384Sync, sha512, sha512Sync,
} from "std/crypto/pure/coreNative";
import { Buffer } from "std/core/buffer";
import { CryptoError } from "std/crypto/errors";

function must<T>(sink result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function hex(bytes: Buffer): string {
	return toHex(bytes);
}

const abc = [
	"900150983cd24fb0d6963f7d28e17f72",
	"a9993e364706816aba3e25717850c26c9cd0d89d",
	"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	"cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed" +
		"8086072ba1e7cc2358baeca134c825a7",
	"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" +
		"2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
];

test "private core init and cleanup keep the native lifecycle contract" {
	assert init();
	assert init();
	cleanup();
	assert init();
	assert hex(must(sha256Sync("abc"))) == abc[2];
}

test "private named digest shortcuts match FIPS abc vectors sync and async" {
	assert hex(must(md5Sync("abc"))) == abc[0];
	assert hex(must(sha1Sync("abc"))) == abc[1];
	assert hex(must(sha256Sync("abc"))) == abc[2];
	assert hex(must(sha384Sync("abc"))) == abc[3];
	assert hex(must(sha512Sync("abc"))) == abc[4];
	assert hex(must(await md5("abc"))) == abc[0];
	assert hex(must(await sha1("abc"))) == abc[1];
	assert hex(must(await sha256("abc"))) == abc[2];
	assert hex(must(await sha384("abc"))) == abc[3];
	assert hex(must(await sha512("abc"))) == abc[4];
	const bytes = [97, 98, 99] as uint8[];
	assert hex(must(await sha256(bytes))) == abc[2];
}

test "private async digest and hmac match RFC4231" {
	assert hex(must(await digest("sha256", "abc"))) == abc[2];
	assert hex(must(await digest("sha3-256", ""))) ==
		"a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a";
	const mac = must(await hmac("sha256", "Jefe", "what do ya want for nothing?"));
	assert hex(mac) ==
		"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843";
}
