import {
	randomBytesSync, randomIntSync, randomUUIDSync, timingSafeEqual,
	toHex, fromHex, toBase64, fromBase64, createHash, createHmac, digestSync,
	hmacSync, getHashes, isHashSupported, encodedHash, base64String,
	HashAlgorithm,
} from "./coreNative";
import { CryptoError } from "../errors";

function got<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

test "base64 matches the RFC 4648 section 10 vectors" {
	const plain = ["", "f", "fo", "foo", "foob", "fooba", "foobar"];
	const coded = ["", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"];
	for (let i = 0; i < plain.length; i++) {
		assert toBase64(plain[i]) == coded[i];
		assert base64String(plain[i]) == coded[i];
		const back = fromBase64(coded[i]);
		assert back.ok;
		assert toHex(back.value) == toHex(plain[i]);
	}
}

test "fromBase64 refuses malformed input" {
	for (const text of ["Zg=", "Z===", "Zm9v!", "AA=A", "Zm9", "Zg==Zg=="]) {
		assert !fromBase64(text).ok;
	}
}

test "hex round-trips and refuses bad digits or odd length" {
	assert toHex("") == "";
	assert toHex("\u0000ÿ") == "00c3bf";
	const bytes = fromHex("00ff10Ab");
	assert bytes.ok;
	assert toHex(bytes.value) == "00ff10ab";
	assert fromHex("").ok;
	for (const text of ["abc", "zz", "0g", "0"]) {
		assert !fromHex(text).ok;
	}
}

test "randomUUID is a version 4 RFC 4122 UUID" {
	for (let n = 0; n < 32; n++) {
		const drawn = randomUUIDSync();
		assert drawn.ok;
		const id = drawn.value;
		assert id.length == 36;
		assert id[8] == "-" && id[13] == "-" && id[18] == "-" && id[23] == "-";
		assert id[14] == "4";
		assert "89ab".includes(id[19]);
		const digits = fromHex(id.replaceAll("-", ""));
		assert digits.ok;
	}
	assert got(randomUUIDSync()) != got(randomUUIDSync());
}

test "randomInt stays in range and refuses bad ranges" {
	for (let n = 0; n < 200; n++) {
		const one = randomIntSync(5, 6);
		assert one.ok && one.value == 5;
		const small = randomIntSync(-3, 3);
		assert small.ok && small.value >= -3 && small.value < 3;
		const wide = randomIntSync(0, 281474976710655);
		assert wide.ok && wide.value >= 0 && wide.value < 281474976710655;
	}
	let seen = [false, false, false];
	for (let n = 0; n < 300; n++) seen[got(randomIntSync(0, 3))] = true;
	assert seen[0] && seen[1] && seen[2];
	assert !randomIntSync(3, 3).ok;
	assert !randomIntSync(4, 3).ok;
	assert !randomIntSync(0, 281474976710656).ok;
	assert !randomIntSync(0.5, 3).ok;
	assert !randomIntSync(0, 9007199254740992).ok;
}

test "randomBytes draws the asked length" {
	for (const size of [0, 1, 32, 1048576]) {
		const drawn = randomBytesSync(size);
		assert drawn.ok;
		assert drawn.value.length == size;
	}
	const big = got(randomBytesSync(1048576));
	let nonZero = 0;
	for (let i = 0; i < 64; i++) if (big[i] != 0) nonZero += 1;
	assert nonZero > 32;
	assert !randomBytesSync(-1).ok;
	assert !randomBytesSync(1.5).ok;
}

test "timingSafeEqual compares bytes and refuses unequal lengths" {
	assert timingSafeEqual("", "");
	assert timingSafeEqual("abc", "abc");
	assert !timingSafeEqual("abc", "abd");
	assert !timingSafeEqual("bbc", "abc");
	assert !timingSafeEqual("abc", "abcd");
	assert !timingSafeEqual("", "a");
	const a = got(fromHex("00ff80"));
	const b = got(fromHex("00ff81"));
	assert timingSafeEqual(a, a);
	assert !timingSafeEqual(a, b);
}

test "streaming hash and HMAC equal the one-shot result for every hash" {
	const hashes = getHashes();
	assert hashes.length >= 11;
	const message = "The quick brown fox jumps over the lazy dog".repeat(5);
	for (const name of hashes) {
		assert isHashSupported(name);
		const whole = toHex(got(digestSync(name, message)));
		const h = createHash(name);
		h.update(message.slice(0, 7)).update("").update(message.slice(7));
		assert toHex(h.digest()) == whole;
		assert encodedHash(name, message, "hex") == whole;
		const mac = toHex(got(hmacSync(name, "key", message)));
		const m = createHmac(name, "key");
		m.update(message.slice(0, 100)).update(message.slice(100));
		assert toHex(m.digest()) == mac;
	}
	assert toHex(got(digestSync("sha256", "abc"))) ==
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	assert !isHashSupported("sha0");
	for (const name of ["ripemd160", "sha3-224", "sha3-256", "sha3-384", "sha3-512"] as HashAlgorithm[]) {
		assert isHashSupported(name);
	}
	assert encodedHash("nope", "x", "hex") == "";
}

test "ripemd160 and sha3 known-answer vectors" {
	const h = (name: HashAlgorithm, msg: string): string =>
		toHex(got(digestSync(name, msg)));
	assert h("ripemd160", "") == "9c1185a5c5e9fc54612808977ee8f548b2258d31";
	assert h("ripemd160", "abc") == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc";
	assert h("ripemd160", "The quick brown fox jumps over the lazy dog") == "37f332f68db77bd9d7edd4969571ad671cf9dd3b";
	assert h("sha3-256", "") == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a";
	assert h("sha3-256", "abc") == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
	assert h("sha3-224", "") == "6b4e03423667dbb73b6e15454f0eb1abd4597f9a1b078e3f5b5a6bc7";
	assert h("sha3-224", "abc") == "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf";
	assert h("sha3-384", "") == "0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004";
	assert h("sha3-384", "abc") == "ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25";
	assert h("sha3-512", "") == "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26";
	assert h("sha3-512", "abc") == "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0";
}

test "ripemd160 and sha3 block/rate boundary streaming" {
	const check = (name: HashAlgorithm, boundaries: int32[]): void => {
		for (const n of boundaries) {
			const data = new Array<uint8>(n);
			for (let i = 0; i < n; i++) data[i] = ((i * 7 + 13) & 255) as uint8;
			const whole = toHex(got(digestSync(name, data)));
			for (const cut of [0, 1, n >> 1, n]) {
				const h = createHash(name);
				h.update(data.slice(0, cut)).update(data.slice(cut));
				assert toHex(h.digest()) == whole;
			}
		}
	};
	check("ripemd160", [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 129]);
	check("sha3-224", [0, 1, 143, 144, 145, 288, 289]);
	check("sha3-256", [0, 1, 135, 136, 137, 272, 273]);
	check("sha3-384", [0, 1, 103, 104, 105, 208, 209]);
	check("sha3-512", [0, 1, 71, 72, 73, 144, 145]);
}

test "ripemd160 and sha3 HMAC with long key, empty and binary-NUL messages" {
	const longKey = new Array<uint8>(200);
	for (let i = 0; i < 200; i++) longKey[i] = (i & 255) as uint8;
	const msg = new Array<uint8>(50);
	for (let i = 0; i < 50; i++) msg[i] = (i * 3 & 255) as uint8;
	const empty: uint8[] = [];
	const nulMsg = new Array<uint8>(10);
	for (const name of ["ripemd160", "sha3-224", "sha3-256", "sha3-384", "sha3-512"] as HashAlgorithm[]) {
		const r1 = hmacSync(name, longKey, msg);
		assert r1.ok;
		const m1 = createHmac(name, longKey);
		m1.update(msg);
		assert toHex(m1.digest()) == toHex(r1.value);
		const r2 = hmacSync(name, "k", empty);
		assert r2.ok;
		const m2 = createHmac(name, "k");
		assert toHex(m2.digest()) == toHex(r2.value);
		const r3 = hmacSync(name, "k", nulMsg);
		assert r3.ok;
		const m3 = createHmac(name, "k");
		m3.update(nulMsg);
		assert toHex(m3.digest()) == toHex(r3.value);
	}
}
