// @xfail(raiser): raiser runtime error: attempt to access a nil address
// Parity program — Map keyed by a scalar other than int32/number/string finds
// what it stores: 64-bit keys differing only above bit 31, floats and booleans,
// read from a local, through a key parameter and through an interface field.

interface Atlas {
	index: Map<uint64, int32>;
	signed: Map<int64, int32>;
}

function holdsU(m: Map<uint64, int32>, key: uint64): boolean { return m.has(key); }
function holdsI(m: Map<int64, int32>, key: int64): boolean { return m.has(key); }

function uKey(i: int32): uint64 {
	const shift = ((i % 5) * 8 + 8) as uint64;
	return ((i as uint64) << shift) | (7 as uint64);
}

function iKey(i: int32): int64 { return -(uKey(i) as int64); }

function main(): void {
	const atlas: Atlas = { index: new Map<uint64, int32>(), signed: new Map<int64, int32>() };
	const u = new Map<uint64, int32>();
	const s = new Map<int64, int32>();
	for (let i = 0; i < 40; i++) {
		u.set(uKey(i), i);
		s.set(iKey(i), i);
		atlas.index.set(uKey(i), i);
		atlas.signed.set(iKey(i), i);
	}
	let local = 0;
	let param = 0;
	let field = 0;
	let values = 0;
	for (let i = 0; i < 40; i++) {
		if (u.has(uKey(i)) && s.has(iKey(i))) local++;
		if (holdsU(u, uKey(i)) && holdsI(s, iKey(i))) param++;
		if (atlas.index.has(uKey(i)) && atlas.signed.has(iKey(i))) field++;
		if ((u.get(uKey(i)) ?? -1) == i) values++;
	}
	console.log(`sizes=${u.size},${s.size} local=${local} param=${param} field=${field} values=${values}`);
	console.log(`miss=${u.has(uKey(40))},${holdsU(u, 1 as uint64)}`);

	const f = new Map<float32, int32>();
	f.set(1.5 as float32, 1);
	const b = new Map<boolean, int32>();
	b.set(true, 1);
	const w = new Map<uint16, int32>();
	w.set(65535 as uint16, 1);
	console.log(`float32=${f.has(1.5 as float32)} bool=${b.has(true)},${b.has(false)} uint16=${w.has(65535 as uint16)}`);
}

main();
