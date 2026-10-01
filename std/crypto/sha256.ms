export struct Sha256Digest {
	bytes: uint8[32];
}

function rotateRight(value: uint32, count: uint32): uint32 {
	return (value >> count) | (value << (32 - count));
}

function paddedByte(data: Readonly<Span<uint8>>, at: uint64, padded: uint64): uint32 {
	const length = data.length as uint64;
	if (at < length) { return data[at as int64] as uint32; }
	if (at == length) { return 0x80; }
	if (at < padded - 8) { return 0; }
	const shift = (padded - 1 - at) * 8;
	return (((length * 8) >> shift) & 0xff) as uint32;
}

export function sha256(data: Readonly<Span<uint8>>): Sha256Digest {
	const rounds: uint32[64] = [
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
		0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
		0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
		0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
		0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
		0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
		0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
		0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
		0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	];
	let state: uint32[8] = [
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c,
		0x1f83d9ab, 0x5be0cd19,
	];
	let schedule: uint32[64] = [
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0,
	];
	const padded = ((data.length as uint64) + 9 + 63) / 64 * 64;
	for (let block: uint64 = 0; block < padded; block += 64) {
		for (let t = 0; t < 16; t++) {
			let word: uint32 = 0;
			for (let b = 0; b < 4; b++) {
				word = (word << 8) | paddedByte(data, block + ((t * 4 + b) as uint64), padded);
			}
			schedule[t] = word;
		}
		for (let t = 16; t < 64; t++) {
			const early = schedule[t - 15];
			const late = schedule[t - 2];
			const sigma0 = rotateRight(early, 7) ^ rotateRight(early, 18) ^ (early >> 3);
			const sigma1 = rotateRight(late, 17) ^ rotateRight(late, 19) ^ (late >> 10);
			schedule[t] = schedule[t - 16] + sigma0 + schedule[t - 7] + sigma1;
		}
		let a = state[0];
		let b = state[1];
		let c = state[2];
		let d = state[3];
		let e = state[4];
		let f = state[5];
		let g = state[6];
		let h = state[7];
		for (let t = 0; t < 64; t++) {
			const sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
			const choose = (e & f) ^ (~e & g);
			const first = h + sum1 + choose + rounds[t] + schedule[t];
			const sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
			const majority = (a & b) ^ (a & c) ^ (b & c);
			h = g;
			g = f;
			f = e;
			e = d + first;
			d = c;
			c = b;
			b = a;
			a = first + sum0 + majority;
		}
		state[0] = state[0] + a;
		state[1] = state[1] + b;
		state[2] = state[2] + c;
		state[3] = state[3] + d;
		state[4] = state[4] + e;
		state[5] = state[5] + f;
		state[6] = state[6] + g;
		state[7] = state[7] + h;
	}
	let digest: Sha256Digest = {
		bytes: [
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		],
	};
	for (let i = 0; i < 8; i++) {
		digest.bytes[i * 4] = (state[i] >> 24) as uint8;
		digest.bytes[i * 4 + 1] = ((state[i] >> 16) & 0xff) as uint8;
		digest.bytes[i * 4 + 2] = ((state[i] >> 8) & 0xff) as uint8;
		digest.bytes[i * 4 + 3] = (state[i] & 0xff) as uint8;
	}
	return digest;
}

export function toHex(this digest: Sha256Digest): string {
	const digits = "0123456789abcdef";
	let text = "";
	for (let i = 0; i < 32; i++) {
		const high = (digest.bytes[i] >> 4) as int32;
		const low = (digest.bytes[i] & 15) as int32;
		text += digits.slice(high, high + 1) + digits.slice(low, low + 1);
	}
	return text;
}

@comptime function digestAtCompileTime(text: string): Sha256Digest {
	return sha256(text.asBytes());
}

test "sha256 of the empty input" {
	const expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
	assert sha256("".asBytes()).toHex() == expected;
}

test "sha256 of abc" {
	const expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	assert sha256("abc".asBytes()).toHex() == expected;
}

test "sha256 of a 56-byte input that needs a second padding block" {
	const input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
	const expected = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
	assert sha256(input.asBytes()).toHex() == expected;
}

test "sha256 of 200 bytes spanning four blocks" {
	let input = "";
	for (let i = 0; i < 200; i++) { input += "a"; }
	const expected = "c2a908d98f5df987ade41b5fce213067efbcc21ef2240212a41e54b5e7c28ae5";
	assert sha256(input.asBytes()).toHex() == expected;
}

test "sha256 at compile time matches run time" {
	const folded: Sha256Digest = @comptime { return digestAtCompileTime("account:Escrow"); };
	assert folded == sha256("account:Escrow".asBytes());
	assert folded.bytes[0] == 0x1f && folded.bytes[7] == 0x9b;
}
