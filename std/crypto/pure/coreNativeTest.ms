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
	assert hashes.length >= 6;
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
	const missing: HashAlgorithm = "ripemd160";
	assert isHashSupported(missing) || !digestSync(missing, "").ok;
	assert encodedHash("nope", "x", "hex") == "";
}
