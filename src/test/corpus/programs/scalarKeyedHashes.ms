// @stdout: true true false 2 max 30 false c true false 2
// note: integer and float keys hash through the 128-bit multiply mix on every lane: a HashSet of int32 with a negative member and a repeat, a HashMap keyed by uint64 at its maximum, a Map keyed by int64, and a HashMap keyed by float64 with a negative key and an overwrite. Same output on every lane.

const small = new HashSet<int32>();
small.add(4);
small.add(-9);
small.add(4);
const wide = new HashMap<uint64, string>();
wide.set(0xFFFFFFFFFFFFFFFF as uint64, "max");
wide.set(12345678901 as uint64, "mid");
const m = new Map<int64, int32>();
m.set(7 as int64, 70);
m.set(-3 as int64, 30);
const real = new HashMap<float64, string>();
real.set(1.5, "a");
real.set(-0.25, "b");
real.set(1.5, "c");
console.log(`${small.has(4)} ${small.has(-9)} ${small.has(5)} ${small.size}`
	+ ` ${wide.get(0xFFFFFFFFFFFFFFFF as uint64)!} ${m.get(-3 as int64)!} ${m.has(8 as int64)}`
	+ ` ${real.get(1.5)!} ${real.has(-0.25)} ${real.has(2.0)} ${real.size}`);
