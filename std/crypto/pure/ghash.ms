/**
 * The GHASH of AES-GCM (NIST SP 800-38D) as a Shoup-style windowed table of the key's doubles, so a block costs
 * `128 / window` lookups. Blocks are read as little-endian words and the table holds the same words.
 */
export class Ghash {
	s0: uint32;
	s1: uint32;
	s2: uint32;
	s3: uint32;
	window: int32;
	windowSize: int32;
	table: uint32[];
}

function swapBytes(n: uint32): uint32 {
	return ((n & 0xff) << 24) | (((n >> 8) & 0xff) << 16) | (((n >> 16) & 0xff) << 8) | (n >> 24);
}

function loadBE(data: Readonly<uint8[]>, at: int32): uint32 {
	return ((data[at] as uint32) << 24) | ((data[at + 1] as uint32) << 16) | ((data[at + 2] as uint32) << 8) | (data[at + 3] as uint32);
}

function loadLE(data: Readonly<uint8[]>, at: int32): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
}

function storeLE(out: uint8[], at: int32, word: uint32): void {
	out[at] = (word & 0xff) as uint8;
	out[at + 1] = ((word >> 8) & 0xff) as uint8;
	out[at + 2] = ((word >> 16) & 0xff) as uint8;
	out[at + 3] = (word >> 24) as uint8;
}

// A precompute window of 2, 4 or 8 bits: a bigger one pays its larger table only on a longer message.
function windowFor(bytes: int32): int32 {
	if (bytes > 65536) return 8;
	if (bytes > 1024) return 4;
	return 2;
}

/** `key` is the 16-byte hash key H; `expectedLength` is the byte count about to be hashed, to size the table. */
export function newGhash(key: Readonly<uint8[]>, expectedLength: int32): Ghash {
	let k0 = loadBE(key, 0);
	let k1 = loadBE(key, 4);
	let k2 = loadBE(key, 8);
	let k3 = loadBE(key, 12);
	// doubles[i] = H * x^i in GHASH's bit order, stored as little-endian words
	const doubles = new Array<uint32>(128 * 4);
	for (let i = 0; i < 128; i++) {
		doubles[i * 4] = swapBytes(k0);
		doubles[i * 4 + 1] = swapBytes(k1);
		doubles[i * 4 + 2] = swapBytes(k2);
		doubles[i * 4 + 3] = swapBytes(k3);
		const high = k3 & 1;
		k3 = (k2 << 31) | (k3 >> 1);
		k2 = (k1 << 31) | (k2 >> 1);
		k1 = (k0 << 31) | (k1 >> 1);
		k0 = (k0 >> 1) ^ (high == 1 ? (0xe1000000 as uint32) : (0 as uint32));
	}
	const window = windowFor(expectedLength);
	const windows = 128 / window;
	const windowSize = 1 << window;
	const table = new Array<uint32>(windows * windowSize * 4);
	for (let w = 0; w < windows; w++) {
		for (let value = 0; value < windowSize; value++) {
			let s0: uint32 = 0;
			let s1: uint32 = 0;
			let s2: uint32 = 0;
			let s3: uint32 = 0;
			for (let j = 0; j < window; j++) {
				if (((value >> (window - j - 1)) & 1) == 0) continue;
				const at = (window * w + j) * 4;
				s0 = s0 ^ doubles[at];
				s1 = s1 ^ doubles[at + 1];
				s2 = s2 ^ doubles[at + 2];
				s3 = s3 ^ doubles[at + 3];
			}
			const into = (w * windowSize + value) * 4;
			table[into] = s0;
			table[into + 1] = s1;
			table[into + 2] = s2;
			table[into + 3] = s3;
		}
	}
	return { s0: 0, s1: 0, s2: 0, s3: 0, window, windowSize, table };
}

function updateBlock(g: Ghash, w0: uint32, w1: uint32, w2: uint32, w3: uint32): void {
	const x0 = w0 ^ g.s0;
	const x1 = w1 ^ g.s1;
	const x2 = w2 ^ g.s2;
	const x3 = w3 ^ g.s3;
	const window = g.window;
	const windowSize = g.windowSize;
	const mask = (windowSize - 1) as uint32;
	const bits = window as uint32;
	const table = g.table;
	let o0: uint32 = 0;
	let o1: uint32 = 0;
	let o2: uint32 = 0;
	let o3: uint32 = 0;
	let w = 0;
	for (let word = 0; word < 4; word++) {
		const num = word == 0 ? x0 : word == 1 ? x1 : word == 2 ? x2 : x3;
		for (let bytePos = 0; bytePos < 4; bytePos++) {
			const byte = (num >> ((8 * bytePos) as uint32)) & 0xff;
			for (let bitPos = 8 / window - 1; bitPos >= 0; bitPos--) {
				const lookup = ((byte >> (bits * (bitPos as uint32))) & mask) as int32;
				const at = (w * windowSize + lookup) * 4;
				o0 = o0 ^ table[at];
				o1 = o1 ^ table[at + 1];
				o2 = o2 ^ table[at + 2];
				o3 = o3 ^ table[at + 3];
				w++;
			}
		}
	}
	g.s0 = o0;
	g.s1 = o1;
	g.s2 = o2;
	g.s3 = o3;
}

/** Absorbs `data[from, to)` as one segment, zero-padded to a whole block: AAD, cipher text and the length block are separate segments. */
export function updateGhash(g: Ghash, data: Readonly<uint8[]>, from: int32, to: int32): void {
	let at = from;
	while (at + 16 <= to) {
		updateBlock(g, loadLE(data, at), loadLE(data, at + 4), loadLE(data, at + 8), loadLE(data, at + 12));
		at += 16;
	}
	if (at < to) {
		const tail = new Array<uint8>(16);
		for (let i = at; i < to; i++) tail[i - at] = data[i];
		updateBlock(g, loadLE(tail, 0), loadLE(tail, 4), loadLE(tail, 8), loadLE(tail, 12));
	}
}

/** Writes the 16-byte hash to `out[at, at + 16)`. */
export function finishGhash(g: Ghash, out: uint8[], at: int32): void {
	storeLE(out, at, g.s0);
	storeLE(out, at + 4, g.s1);
	storeLE(out, at + 8, g.s2);
	storeLE(out, at + 12, g.s3);
}
