// 64-bit lane words stored as (lo, hi) uint32 pairs; JS has no cheap 64-bit integer.
// Derived from Zig std.crypto keccak_p.zig + sha3.zig, commit 16d31ceed5de91b469e010b4a8d515236ad6bf14; see LICENSE.sha3.

const RC_LO: uint32[24] = [
	0x00000001, 0x00008082, 0x0000808a, 0x80008000,
	0x0000808b, 0x80000001, 0x80008081, 0x00008009,
	0x0000008a, 0x00000088, 0x80008009, 0x8000000a,
	0x8000808b, 0x0000008b, 0x00008089, 0x00008003,
	0x00008002, 0x00000080, 0x0000800a, 0x8000000a,
	0x80008081, 0x00008080, 0x80000001, 0x80008008,
];
const RC_HI: uint32[24] = [
	0x00000000, 0x00000000, 0x80000000, 0x80000000,
	0x00000000, 0x00000000, 0x80000000, 0x80000000,
	0x00000000, 0x00000000, 0x00000000, 0x00000000,
	0x00000000, 0x80000000, 0x80000000, 0x80000000,
	0x80000000, 0x80000000, 0x00000000, 0x80000000,
	0x80000000, 0x80000000, 0x00000000, 0x80000000,
];

const PI: int32[24] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1];

function rotlLo(lo: uint32, hi: uint32, n: int32): uint32 {
	if (n == 0) return lo;
	if (n < 32) { const s = n as uint32; return (lo << s) | (hi >> (32 - s)); }
	if (n == 32) return hi;
	const s = (n - 32) as uint32;
	return (hi << s) | (lo >> (32 - s));
}

function rotlHi(lo: uint32, hi: uint32, n: int32): uint32 {
	if (n == 0) return hi;
	if (n < 32) { const s = n as uint32; return (hi << s) | (lo >> (32 - s)); }
	if (n == 32) return lo;
	const s = (n - 32) as uint32;
	return (lo << s) | (hi >> (32 - s));
}

function keccakF(st: uint32[]): void {
	let c: uint32[10] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	let row: uint32[10] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	let lastLo: uint32 = 0;
	let lastHi: uint32 = 0;
	let tmpLo: uint32 = 0;
	let tmpHi: uint32 = 0;
	for (let round = 0; round < 24; round++) {
		for (let x = 0; x < 5; x++) {
			c[x*2]   = st[x*2]   ^ st[(x+5)*2]   ^ st[(x+10)*2]   ^ st[(x+15)*2]   ^ st[(x+20)*2];
			c[x*2+1] = st[x*2+1] ^ st[(x+5)*2+1] ^ st[(x+10)*2+1] ^ st[(x+15)*2+1] ^ st[(x+20)*2+1];
		}
		for (let lane = 0; lane < 25; lane++) {
			const x = lane % 5;
			const d0 = (x + 4) % 5;
			const d1 = (x + 1) % 5;
			st[lane*2]   ^= c[d0*2]   ^ rotlLo(c[d1*2], c[d1*2+1], 1);
			st[lane*2+1] ^= c[d0*2+1] ^ rotlHi(c[d1*2], c[d1*2+1], 1);
		}
		lastLo = st[2]; lastHi = st[3];
		let rotc = 0;
		for (let i = 0; i < 24; i++) {
			const x = PI[i];
			tmpLo = st[x*2]; tmpHi = st[x*2+1];
			rotc = (rotc + i + 1) % 64;
			st[x*2]   = rotlLo(lastLo, lastHi, rotc);
			st[x*2+1] = rotlHi(lastLo, lastHi, rotc);
			lastLo = tmpLo; lastHi = tmpHi;
		}
		for (let y = 0; y < 5; y++) {
			for (let x = 0; x < 5; x++) {
				row[x*2]   = st[(y*5+x)*2];
				row[x*2+1] = st[(y*5+x)*2+1];
			}
			for (let x = 0; x < 5; x++) {
				st[(y*5+x)*2]   = row[x*2]   ^ (~row[((x+1)%5)*2]   & row[((x+2)%5)*2]);
				st[(y*5+x)*2+1] = row[x*2+1] ^ (~row[((x+1)%5)*2+1] & row[((x+2)%5)*2+1]);
			}
		}
		st[0] ^= RC_LO[round];
		st[1] ^= RC_HI[round];
	}
}

function xorIntoState(st: uint32[], data: Readonly<uint8[]>, off: int32, len: int32): void {
	let i = 0;
	while (i + 8 <= len) {
		const j = off + i;
		const lane = i >> 3;
		const lo = (data[j] as uint32) | ((data[j+1] as uint32) << 8) | ((data[j+2] as uint32) << 16) | ((data[j+3] as uint32) << 24);
		const hi = (data[j+4] as uint32) | ((data[j+5] as uint32) << 8) | ((data[j+6] as uint32) << 16) | ((data[j+7] as uint32) << 24);
		st[lane*2]   ^= lo;
		st[lane*2+1] ^= hi;
		i += 8;
	}
	if (i < len) {
		const lane = i >> 3;
		let lo: uint32 = 0;
		let hi: uint32 = 0;
		for (let k = 0; k < len - i; k++) {
			const b = data[off + i + k] as uint32;
			if (k < 4) {
				lo ^= b << ((k * 8) as uint32);
			} else {
				hi ^= b << (((k - 4) * 8) as uint32);
			}
		}
		st[lane*2]   ^= lo;
		st[lane*2+1] ^= hi;
	}
}

function addByteToState(st: uint32[], b: uint8, offset: int32): void {
	const lane = offset >> 3;
	const byteInLane = offset & 7;
	if (byteInLane < 4) {
		st[lane*2]   ^= (b as uint32) << ((byteInLane * 8) as uint32);
	} else {
		st[lane*2+1] ^= (b as uint32) << (((byteInLane - 4) * 8) as uint32);
	}
}

function extractFromState(st: uint32[], out: uint8[], len: int32): void {
	for (let i = 0; i < len; i++) {
		const lane = i >> 3;
		const byteInLane = i & 7;
		let w: uint32;
		if (byteInLane < 4) {
			w = st[lane*2] >> ((byteInLane * 8) as uint32);
		} else {
			w = st[lane*2+1] >> (((byteInLane - 4) * 8) as uint32);
		}
		out[i] = (w & 0xff) as uint8;
	}
}

/** Running state for SHA3-224/256/384/512 (Keccak-f[1600] sponge).
 * st: 25 lanes as (lo, hi) uint32 pairs at indices st[2i] / st[2i+1]. */
export class Sha3State {
	st: uint32[];
	buf: uint8[];
	rate: int32;
	bits: int32;
	filled: int32;
	finished: boolean;
}

/** Returns a new SHA3 state for the given output size (224, 256, 384 or 512 bits). */
export function newSha3(bits: int32): Sha3State {
	if (bits != 224 && bits != 256 && bits != 384 && bits != 512) throw new Error("SHA3: unsupported output size");
	const cap = bits >> 2;
	const rate = 200 - cap;
	return {
		st: new Array<uint32>(50),
		buf: new Array<uint8>(rate),
		rate,
		bits,
		filled: 0,
		finished: false,
	};
}

/** Absorb data into the sponge. Throws if called after finishSha3. */
export function updateSha3(state: Sha3State, data: Readonly<uint8[]>): void {
	if (state.finished) throw new Error("SHA3: already finished");
	const n = data.length as int32;
	const rate = state.rate;
	let i = 0;
	if (state.filled > 0) {
		const space = rate - state.filled;
		const take = space < n ? space : n;
		for (let j = 0; j < take; j++) state.buf[state.filled + j] = data[j];
		state.filled += take;
		if (take == n) return;
		if (state.filled == rate) {
			xorIntoState(state.st, state.buf, 0, rate);
			keccakF(state.st);
			state.filled = 0;
		}
		i = take;
	}
	while (i + rate < n) {
		xorIntoState(state.st, data, i, rate);
		keccakF(state.st);
		i += rate;
	}
	const remaining = n - i;
	for (let j = 0; j < remaining; j++) state.buf[state.filled + j] = data[i + j];
	state.filled += remaining;
}

/** Pad, permute, and return the digest bytes. Throws if called more than once. */
export function finishSha3(state: Sha3State): uint8[] {
	if (state.finished) throw new Error("SHA3: already finished");
	const rate = state.rate;
	xorIntoState(state.st, state.buf, 0, state.filled);
	if (state.filled == rate) {
		keccakF(state.st);
		state.filled = 0;
	}
	addByteToState(state.st, 0x06, state.filled);
	addByteToState(state.st, 0x80, rate - 1);
	keccakF(state.st);
	const digestLen = state.bits >> 3;
	const out = new Array<uint8>(digestLen);
	extractFromState(state.st, out, digestLen);
	state.finished = true;
	return out;
}

/** Hash data in one call. */
export function sha3Of(bits: int32, data: Readonly<uint8[]>): uint8[] {
	const state = newSha3(bits);
	updateSha3(state, data);
	return finishSha3(state);
}

function toHex(bytes: Readonly<uint8[]>): string {
	const digits = "0123456789abcdef";
	let result = "";
	const n = bytes.length as int32;
	for (let i = 0; i < n; i++) {
		const hi = (bytes[i] >> 4) as int32;
		const lo = (bytes[i] as int32) & 15;
		result += digits.slice(hi, hi + 1) + digits.slice(lo, lo + 1);
	}
	return result;
}

const longMsg = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";

test "sha3-224 NIST vectors" {
	assert toHex(sha3Of(224, "".asBytes().slice(0))) == "6b4e03423667dbb73b6e15454f0eb1abd4597f9a1b078e3f5b5a6bc7";
	assert toHex(sha3Of(224, "abc".asBytes().slice(0))) == "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf";
	assert toHex(sha3Of(224, longMsg.asBytes().slice(0))) == "543e6868e1666c1a643630df77367ae5a62a85070a51c14cbf665cbc";
}

test "sha3-256 NIST vectors" {
	assert toHex(sha3Of(256, "".asBytes().slice(0))) == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a";
	assert toHex(sha3Of(256, "abc".asBytes().slice(0))) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
	assert toHex(sha3Of(256, longMsg.asBytes().slice(0))) == "916f6061fe879741ca6469b43971dfdb28b1a32dc36cb3254e812be27aad1d18";
}

test "sha3-384 NIST vectors" {
	assert toHex(sha3Of(384, "".asBytes().slice(0))) == "0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004";
	assert toHex(sha3Of(384, "abc".asBytes().slice(0))) == "ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25";
	assert toHex(sha3Of(384, longMsg.asBytes().slice(0))) == "79407d3b5916b59c3e30b09822974791c313fb9ecc849e406f23592d04f625dc8c709b98b43b3852b337216179aa7fc7";
}

test "sha3-512 NIST vectors" {
	assert toHex(sha3Of(512, "".asBytes().slice(0))) == "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26";
	assert toHex(sha3Of(512, "abc".asBytes().slice(0))) == "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0";
	assert toHex(sha3Of(512, longMsg.asBytes().slice(0))) == "afebb2ef542e6579c50cad06d2e578f9f8dd6881d7dc824d26360feebf18a4fa73e3261122948efcfd492e74e82e2189ed0fb440d187f382270cb455f21dd185";
}

test "sha3-256 split update matches single call" {
	const s = newSha3(256);
	updateSha3(s, "a".asBytes().slice(0));
	updateSha3(s, "bc".asBytes().slice(0));
	assert toHex(finishSha3(s)) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
}

test "sha3-256 rate-boundary flush" {
	const all = new Array<uint8>(137);
	const ref = sha3Of(256, all);
	const s = newSha3(256);
	updateSha3(s, new Array<uint8>(136));
	updateSha3(s, new Array<uint8>(1));
	assert toHex(finishSha3(s)) == toHex(ref);
}

test "sha3-512 split update" {
	const s = newSha3(512);
	updateSha3(s, "a".asBytes().slice(0));
	updateSha3(s, "bc".asBytes().slice(0));
	assert toHex(finishSha3(s)) == "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0";
}

test "sha3 rejects unsupported output sizes" {
	for (const bits of [0, 128, 225, 1024]) {
		let threw = false;
		try {
			newSha3(bits);
		} catch (e) {
			threw = true;
		}
		assert threw;
	}
}

test "sha3 update after finish throws even for empty input" {
	const s = newSha3(256);
	finishSha3(s);
	let threw = false;
	try {
		updateSha3(s, []);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "sha3 finish after finish throws" {
	const s = newSha3(512);
	finishSha3(s);
	let threw = false;
	try {
		finishSha3(s);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "sha3-256 zero input rate boundaries match reference" {
	assert toHex(sha3Of(256, new Array<uint8>(135))) == "7d080d7ba978a75c8a7d1f9be566c859084509c9c2b4928435c225d5777d98e3";
	assert toHex(sha3Of(256, new Array<uint8>(136))) == "e772c9cf9eb9c991cdfcf125001b454fdbc0a95f188d1b4c844aa032ad6e075e";
	assert toHex(sha3Of(256, new Array<uint8>(137))) == "9ed57188470a83b758cd71c00c6cc3beb984b36a6c35864b4e53017b24cf5699";
}

test "sha3-512 zero input rate boundaries match reference" {
	assert toHex(sha3Of(512, new Array<uint8>(71))) == "cd87417194c917561a59c7f2eb4b95145971e32e8e4ef3b23b0f190bfd29e3692cc7975275750a27df95d5c6a99b7a341e1b8a38a750a51aca5b77bae41fbbfc";
	assert toHex(sha3Of(512, new Array<uint8>(72))) == "f8d76fdd8a082a67eaab47b5518ac486cb9a90dcb9f3c9efcfd86d5c8b3f1831601d3c8435f84b9e56da91283d5b98040e6e7b2c8dd9aa5bd4ebdf1823a7cf29";
	assert toHex(sha3Of(512, new Array<uint8>(73))) == "4ed8ba5741d94caef309c190bc13d18eb0f16942ebea76dcf0c6db1a35311fc04611313ea7d0ff2228a131cd68a84b3872c93d75700601107b6addeaffaa7a90";
}

test "sha3-224 zero input rate boundaries match reference" {
	assert toHex(sha3Of(224, new Array<uint8>(143))) == "b6b709fdb9852b8c7439a33595d42dba2940f44c10c3ce09f8b6a87a";
	assert toHex(sha3Of(224, new Array<uint8>(144))) == "f2b8486fceee2c6a11a604ce4efe217da854829c2c2dcc9a23758b4d";
	assert toHex(sha3Of(224, new Array<uint8>(145))) == "361ca40de495e03bd091694f1d1372851105046a1bf6d59fafe7d668";
}

test "sha3-384 zero input rate boundaries match reference" {
	assert toHex(sha3Of(384, new Array<uint8>(103))) == "11c556552dda63418669716bad02e4125f4973f3ceea99ee50b6ff117e9f7a3fed0360abb5eff4ac8e954205c01981d2";
	assert toHex(sha3Of(384, new Array<uint8>(104))) == "aaed6beb61b1f9a9b469d38a27a35edde7f676f4603e67f5424c7588043b869ebbfcfc3ecee2ae6f5ecfaf7f706c49e3";
	assert toHex(sha3Of(384, new Array<uint8>(105))) == "7db7a10350831a0b3c8c94a138a301858dd8c6d589cd1b47f6720f9243162f952161ae945ec8cf7a838d02cfbcc762ee";
}

function counting(n: int32): uint8[] {
	const out = new Array<uint8>(n);
	for (let i = 0; i < n; i++) out[i] = (i & 255) as uint8;
	return out;
}

function splitHex(bits: int32, data: Readonly<uint8[]>, cut: int32): string {
	const s = newSha3(bits);
	updateSha3(s, data.slice(0, cut));
	updateSha3(s, data.slice(cut));
	return toHex(finishSha3(s));
}

function byteByByteHex(bits: int32, data: Readonly<uint8[]>): string {
	const s = newSha3(bits);
	const n = data.length as int32;
	for (let i = 0; i < n; i++) updateSha3(s, data.slice(i, i + 1));
	return toHex(finishSha3(s));
}

test "sha3 multi-block input split at every rate edge matches reference" {
	const data = counting(500);
	const sizes: int32[] = [224, 256, 384, 512];
	const want = [
		"eb7d43dfd550ee5aff6159b3ccaee0715c9c36bbce1822ad7e26702e",
		"0f96259f82fb8c30d3d702e8a89a475d2e96690a5ee9892a48351864fb492aa5",
		"88587b396e4297ab27908fb4741a3259372e6dd8fa62b22912d0c60afc4eb89cfd6a7baa7f8690f6be874140b1d52713",
		"5c371829f774959d04ac4b4e49557e4355427407ca960a3acc9643bb5b13cb692bbe281f3f4137784551092b4613e016a4f1ff2714f8f67f97d11e3233a9b662",
	];
	for (let k = 0; k < 4; k++) {
		const bits = sizes[k];
		const rate = 200 - (bits >> 2);
		assert toHex(sha3Of(bits, data)) == want[k];
		const cuts: int32[] = [0, 1, rate - 1, rate, rate + 1, 2 * rate, 499, 500];
		for (const cut of cuts) assert splitHex(bits, data, cut) == want[k];
		assert byteByByteHex(bits, data) == want[k];
	}
}

test "sha3-256 of a million a fed in uneven chunks" {
	const s = newSha3(256);
	const big = new Array<uint8>(1000);
	for (let i = 0; i < 1000; i++) big[i] = 97;
	const odd = new Array<uint8>(7);
	for (let i = 0; i < 7; i++) odd[i] = 97;
	for (let i = 0; i < 500; i++) updateSha3(s, big);
	for (let i = 0; i < 71428; i++) updateSha3(s, odd);
	for (let i = 0; i < 4; i++) updateSha3(s, odd.slice(0, 1));
	assert toHex(finishSha3(s)) == "5c8875ae474a3634ba4fd55ec85bffd661f32aca75c6d699d0cdcb6c115891c1";
}
