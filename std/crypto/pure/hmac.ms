import { HashState, kindSha1, kindSha256, kindSha512, kindMd5 } from "./state";
import { encodeHex } from "../../core/encoding";
import { newHash, copyHash, updateHash, finishHashInto, hashOf } from "./hash";

/** HMAC with the keyed pad blocks absorbed once, so each message restarts from a copy instead of rehashing the key. */
export class HmacState {
	inner: HashState;
	outer: HashState;
	innerKeyed: HashState;
	outerKeyed: HashState;
	innerDigest: uint8[];
}

export function newHmac(kind: int32, key: Readonly<uint8[]>): HmacState {
	const probe = newHash(kind);
	const size = probe.blockSize;
	const keyBlock = new Array<uint8>(size);
	const shortKey = key.length > size ? hashOf(kind, key) : key;
	for (let i = 0; i < shortKey.length; i++) keyBlock[i] = shortKey[i];
	const pad = new Array<uint8>(size);
	const innerKeyed = newHash(kind);
	for (let i = 0; i < size; i++) pad[i] = keyBlock[i] ^ 0x36;
	updateHash(innerKeyed, pad);
	const outerKeyed = newHash(kind);
	for (let i = 0; i < size; i++) pad[i] = keyBlock[i] ^ 0x5c;
	updateHash(outerKeyed, pad);
	const hmac: HmacState = {
		inner: newHash(kind),
		outer: newHash(kind),
		innerKeyed,
		outerKeyed,
		innerDigest: new Array<uint8>(probe.outputSize),
	};
	copyHash(innerKeyed, hmac.inner);
	return hmac;
}

export function updateHmac(hmac: HmacState, data: Readonly<uint8[]>): void {
	updateHash(hmac.inner, data);
}

/** Writes the MAC to `out` and restarts the state on the same key. */
export function finishHmacInto(hmac: HmacState, out: uint8[]): void {
	finishHashInto(hmac.inner, hmac.innerDigest);
	copyHash(hmac.outerKeyed, hmac.outer);
	updateHash(hmac.outer, hmac.innerDigest);
	finishHashInto(hmac.outer, out);
	copyHash(hmac.innerKeyed, hmac.inner);
}

export function finishHmac(hmac: HmacState): uint8[] {
	const out = new Array<uint8>(hmac.inner.outputSize);
	finishHmacInto(hmac, out);
	return out;
}

export function hmacOf(kind: int32, key: Readonly<uint8[]>, data: Readonly<uint8[]>): uint8[] {
	const hmac = newHmac(kind, key);
	updateHmac(hmac, data);
	return finishHmac(hmac);
}

export function pbkdf2Of(kind: int32, password: Readonly<uint8[]>, salt: Readonly<uint8[]>, iterations: int32, length: int32): uint8[] {
	const hmac = newHmac(kind, password);
	const size = hmac.inner.outputSize;
	const out = new Array<uint8>(length);
	const block = new Array<uint8>(size);
	const running = new Array<uint8>(size);
	const counter = new Array<uint8>(4);
	let written = 0;
	let index = 1;
	while (written < length) {
		counter[0] = ((index >> 24) & 255) as uint8;
		counter[1] = ((index >> 16) & 255) as uint8;
		counter[2] = ((index >> 8) & 255) as uint8;
		counter[3] = (index & 255) as uint8;
		updateHmac(hmac, salt);
		updateHmac(hmac, counter);
		finishHmacInto(hmac, running);
		for (let i = 0; i < size; i++) block[i] = running[i];
		for (let round = 1; round < iterations; round++) {
			updateHmac(hmac, running);
			finishHmacInto(hmac, running);
			for (let i = 0; i < size; i++) block[i] = block[i] ^ running[i];
		}
		for (let i = 0; i < size && written < length; i++) {
			out[written] = block[i];
			written += 1;
		}
		index += 1;
	}
	return out;
}

export function hkdfOf(kind: int32, ikm: Readonly<uint8[]>, salt: Readonly<uint8[]>, info: Readonly<uint8[]>, length: int32): uint8[] {
	const size = newHash(kind).outputSize;
	const zeros = new Array<uint8>(size);
	const prk = hmacOf(kind, salt.length == 0 ? zeros : salt, ikm);
	const hmac = newHmac(kind, prk);
	const out = new Array<uint8>(length);
	const block = new Array<uint8>(size);
	const counter = new Array<uint8>(1);
	let written = 0;
	let index = 1;
	while (written < length) {
		if (index > 1) updateHmac(hmac, block);
		updateHmac(hmac, info);
		counter[0] = index as uint8;
		updateHmac(hmac, counter);
		finishHmacInto(hmac, block);
		for (let i = 0; i < size && written < length; i++) {
			out[written] = block[i];
			written += 1;
		}
		index += 1;
	}
	return out;
}

function repeated(count: int32, value: uint8): uint8[] {
	const out = new Array<uint8>(count);
	for (let i = 0; i < count; i++) out[i] = value;
	return out;
}

function text(value: string): uint8[] {
	return value.asBytes().slice(0);
}

test "hmac vectors from RFC 4231 and RFC 2202" {
	const short = repeated(20, 0x0b);
	assert hmacOf(kindSha256, short, text("Hi There")).encodeHex() == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
	assert hmacOf(kindSha512, short, text("Hi There")).encodeHex() == "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854";
	assert hmacOf(kindSha1, short, text("Hi There")).encodeHex() == "b617318655057264e28bc0b6fb378c8ef146be00";
	assert hmacOf(kindMd5, repeated(16, 0x0b), text("Hi There")).encodeHex() == "9294727a3638bb1c13f48ef8158bfc9d";
	const long = repeated(131, 0xaa);
	assert hmacOf(kindSha256, long, text("Test Using Larger Than Block-Size Key - Hash Key First")).encodeHex() == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54";
}

test "pbkdf2 vectors from RFC 6070 and the SHA-256 companion" {
	assert pbkdf2Of(kindSha1, text("password"), text("salt"), 1, 20).encodeHex() == "0c60c80f961f0e71f3a9b524af6012062fe037a6";
	assert pbkdf2Of(kindSha1, text("password"), text("salt"), 2, 20).encodeHex() == "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957";
	assert pbkdf2Of(kindSha1, text("password"), text("salt"), 4096, 20).encodeHex() == "4b007901b765489abead49d926f721d065a429c1";
	assert pbkdf2Of(kindSha256, text("password"), text("salt"), 1, 32).encodeHex() == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b";
}

test "hkdf vectors from RFC 5869" {
	const salt = new Array<uint8>(13);
	for (let i = 0; i < 13; i++) salt[i] = i as uint8;
	const info = new Array<uint8>(10);
	for (let i = 0; i < 10; i++) info[i] = (0xf0 + i) as uint8;
	assert hkdfOf(kindSha256, repeated(22, 0x0b), salt, info, 42).encodeHex() == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865";
	const none = new Array<uint8>(0);
	assert hkdfOf(kindSha256, repeated(22, 0x0b), none, none, 42).encodeHex() == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8";
}
