import { HashState, kindSha256, kindMd5 } from "./state";
import { newHash, copyHash, updateHash, finishHash, finishHashInto, hashOf } from "./hash";

const pbkdf2MaxLength = 1048576;

/** HMAC with the keyed pad blocks absorbed once, so each message restarts from a copy instead of rehashing the key. */
export class HmacState {
	inner: HashState;
	outer: HashState;
	innerKeyed: HashState;
	outerKeyed: HashState;
	innerDigest: uint8[];
}

function wipe(bytes: uint8[]): void {
	for (let i = 0; i < bytes.length; i++) bytes[i] = 0;
}

function wipeHash(h: HashState): void {
	for (let i = 0; i < 16; i++) h.state[i] = 0;
	for (let i = 0; i < 160; i++) h.schedule[i] = 0;
	wipe(h.block);
}

function wipeHmac(hmac: HmacState): void {
	wipeHash(hmac.inner);
	wipeHash(hmac.outer);
	wipeHash(hmac.innerKeyed);
	wipeHash(hmac.outerKeyed);
	wipe(hmac.innerDigest);
}

function requireKind(kind: int32): void {
	if (kind < kindSha256 || kind > kindMd5) throw new Error(`hmac: unknown hash kind ${kind}`);
}

/** Absorbs key ^ ipad into `inner` and key ^ opad into `outer`, hashing a key longer than one block first. */
function absorbPads(key: Readonly<uint8[]>, inner: HashState, outer: HashState): void {
	const size = inner.blockSize;
	const pad = new Array<uint8>(size);
	if (key.length > size) {
		const digest = hashOf(inner.kind, key);
		for (let i = 0; i < digest.length; i++) pad[i] = digest[i];
		wipe(digest);
	} else {
		for (let i = 0; i < key.length; i++) pad[i] = key[i];
	}
	for (let i = 0; i < size; i++) pad[i] = pad[i] ^ 0x36;
	updateHash(inner, pad);
	for (let i = 0; i < size; i++) pad[i] = pad[i] ^ (0x36 ^ 0x5c);
	updateHash(outer, pad);
	wipe(pad);
}

export function newHmac(kind: int32, key: Readonly<uint8[]>): HmacState {
	requireKind(kind);
	const innerKeyed = newHash(kind);
	const outerKeyed = newHash(kind);
	absorbPads(key, innerKeyed, outerKeyed);
	const hmac: HmacState = {
		inner: newHash(kind),
		outer: newHash(kind),
		innerKeyed,
		outerKeyed,
		innerDigest: new Array<uint8>(innerKeyed.outputSize),
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
	wipe(hmac.innerDigest);
	wipe(hmac.outer.block);
	copyHash(hmac.innerKeyed, hmac.inner);
}

export function finishHmac(hmac: HmacState): uint8[] {
	const out = new Array<uint8>(hmac.inner.outputSize);
	finishHmacInto(hmac, out);
	return out;
}

export function hmacOf(kind: int32, key: Readonly<uint8[]>, data: Readonly<uint8[]>): uint8[] {
	requireKind(kind);
	const inner = newHash(kind);
	const outer = newHash(kind);
	absorbPads(key, inner, outer);
	updateHash(inner, data);
	const innerDigest = finishHash(inner);
	wipeHash(inner);
	updateHash(outer, innerDigest);
	wipe(innerDigest);
	const out = finishHash(outer);
	wipeHash(outer);
	return out;
}

export function pbkdf2Of(kind: int32, password: Readonly<uint8[]>, salt: Readonly<uint8[]>, iterations: int32, length: int32): uint8[] {
	if (iterations < 1) throw new Error("pbkdf2: iterations must be at least 1");
	if (length < 1 || length > pbkdf2MaxLength) throw new Error(`pbkdf2: keyLength must be between 1 and ${pbkdf2MaxLength}`);
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
	wipe(block);
	wipe(running);
	wipeHmac(hmac);
	return out;
}

export function hkdfOf(kind: int32, ikm: Readonly<uint8[]>, salt: Readonly<uint8[]>, info: Readonly<uint8[]>, length: int32): uint8[] {
	requireKind(kind);
	const size = newHash(kind).outputSize;
	if (length < 1) throw new Error("hkdf: length must be at least 1");
	if (length > 255 * size) throw new Error(`hkdf: length must be at most ${255 * size}`);
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
	wipe(prk);
	wipe(block);
	wipeHmac(hmac);
	return out;
}
