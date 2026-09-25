// @xfail(raiser): error: Undefined variable 'Number'
// Parity program — a float key finds its entry by `==`, so NaN never matches: a lookup of NaN
// misses, and each insert of NaN adds an entry of its own. 0 and -0 stay one key. Covers Map,
// HashMap, Set and HashSet, float32, an alias of number, a Map literal, a key reached through a
// generic, and a NaN inside a struct key.
//
// @stdout: map=false,-1,4,false,4,10 keys=1.5,NaN,NaN,0 each=2 hashmap=false,2 set=false,3,false,true,2 hashset=false,2 float32=false,2 alias=false,2 literal=false,2 generic=2,1 struct=false,2 cleared=0,true
// @exit: 0

type Meters = number;

struct Reading { at: number; }

function render(ks: number[]): string {
	let out = "";
	for (const k of ks) {
		let part = k.toString();
		if (k != k) {
			part = "NaN";
		} else if (k == 0) {
			part = "0";
		}
		out = out == "" ? part : out + "," + part;
	}
	return out;
}

function sum(vs: int32[]): int32 {
	let total: int32 = 0;
	for (const v of vs) total = total + v;
	return total;
}

function sizeAfterTwice<K>(k: K): number {
	const m = new Map<K, int32>();
	m.set(k, 1);
	m.set(k, 2);
	return m.size;
}

function main(): void {
	const nan = Number.NaN;

	const m = new Map<number, int32>();
	m.set(1.5, 1);
	m.set(nan, 2);
	m.set(nan, 3);
	m.set(-0.0, 4);
	const found = `${m.has(nan)},${m.get(nan) ?? -1},${m.size},${m.delete(nan)},${m.get(0.0) ?? -1},${sum(m.values())}`;
	let nanVisits: int32 = 0;
	m.forEach((v: int32, k: number) => {
		if (k != k) nanVisits = nanVisits + 1;
	});

	const hm = new HashMap<number, int32>();
	hm.set(nan, 1);
	hm.set(nan, 2);

	const s = new Set<number>();
	s.add(nan);
	s.add(nan);
	s.add(-0.0);
	let setNaNs: int32 = 0;
	for (const v of s.toItems()) {
		if (v != v) setNaNs = setNaNs + 1;
	}

	const hs = new HashSet<number>();
	hs.add(nan);
	hs.add(nan);

	const f32 = new Map<float32, int32>();
	f32.set(nan as float32, 1);
	f32.set(nan as float32, 2);

	const meters = new Set<Meters>();
	meters.add(nan);
	meters.add(nan);

	const literal: Map<number, int32> = {};
	literal.set(nan, 1);
	literal.set(nan, 2);

	const readings = new Map<Reading, int32>();
	readings.set({ at: nan }, 1);
	readings.set({ at: nan }, 2);

	console.log(`map=${found} keys=${render(m.keys())} each=${nanVisits} hashmap=${hm.has(nan)},${hm.size} set=${s.has(nan)},${s.size},${s.delete(nan)},${s.has(0.0)},${setNaNs} hashset=${hs.has(nan)},${hs.size} float32=${f32.has(nan as float32)},${f32.size} alias=${meters.has(nan)},${meters.size} literal=${literal.has(nan)},${literal.size} generic=${sizeAfterTwice(nan)},${sizeAfterTwice(1.5)} struct=${readings.has({ at: nan })},${readings.size} cleared=${clearedSize(m)}`);
}

function clearedSize(m: Map<number, int32>): string {
	m.clear();
	const empty = m.size;
	m.set(2.5, 1);
	return `${empty},${m.has(2.5)}`;
}

main();
