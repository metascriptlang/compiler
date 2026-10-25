// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: map has=200/200 copies=0 · set has=200/200 copies=0
// @stdout: grow map=0 set=0 hashMap=0 hashSet=0 sizes=200,200,200,200
// @stdout: compact map=0 set=0 sizes=10,10 first=191,191

// A lookup reads each probed entry in place, and a resize or compaction moves the entries into
// the new table, as the reference's rawGetKnownHCImpl and enlarge do, so none of them copies a
// key. `grow` and `compact` print the copies of the costliest insert or delete beyond those of
// the cheapest, which is what the one resize or compaction among them adds.

struct Key { id: int32; tag: string; }
export function `==`(x: Key, y: Key): boolean { return x.id == y.id; }
export function hash(this k: Key): int64 { return (k.id as int64) * 7919; }

let copies: int32 = 0;
function onCopy(this ref dest: Key, src: Key): void { copies += 1; dest.id = src.id; dest.tag = src.tag; }

const N: int32 = 200;

function key(i: int32): Key { return { id: i + 1, tag: "k" + i.toString() }; }

function lookups(): string {
	const m = new Map<Key, int32>();
	const s = new Set<Key>();
	for (let i: int32 = 0; i < N + 50; i += 1) {
		m.set(key(i), i);
		s.add(key(i));
	}
	for (let i: int32 = N; i < N + 50; i += 1) {
		m.delete(key(i));
		s.delete(key(i));
	}
	const probes: Key[] = [];
	for (let i: int32 = 0; i < N; i += 1) probes.push(key(i));
	copies = 0;
	let mapHits: int32 = 0;
	for (const k of probes) { if (m.has(k)) mapHits += 1; }
	const mapCopies = copies;
	copies = 0;
	let setHits: int32 = 0;
	for (const k of probes) { if (s.has(k)) setHits += 1; }
	const setCopies = copies;
	return `map has=${mapHits}/${probes.length} copies=${mapCopies} · set has=${setHits}/${probes.length} copies=${setCopies}`;
}

function extra(from: int32, to: int32, step: (i: int32) => void): int32 {
	let most: int32 = 0;
	let least: int32 = 1000000;
	for (let i = from; i < to; i += 1) {
		copies = 0;
		step(i);
		if (copies > most) most = copies;
		if (copies < least) least = copies;
	}
	return most - least;
}

function grow(): string {
	const m = new Map<Key, int32>();
	const s = new Set<Key>();
	const hm = new HashMap<Key, int32>();
	const hs = new HashSet<Key>();
	const a = extra(0, N, (i: int32) => { m.set(key(i), i); });
	const b = extra(0, N, (i: int32) => { s.add(key(i)); });
	const c = extra(0, N, (i: int32) => { hm.set(key(i), i); });
	const d = extra(0, N, (i: int32) => { hs.add(key(i)); });
	return `grow map=${a} set=${b} hashMap=${c} hashSet=${d} sizes=${m.size},${s.size},${hm.size},${hs.size}`;
}

function compact(): string {
	const m = new Map<Key, int32>();
	const s = new Set<Key>();
	for (let i: int32 = 0; i < N; i += 1) {
		m.set(key(i), i);
		s.add(key(i));
	}
	const a = extra(0, N - 10, (i: int32) => { m.delete(key(i)); });
	const b = extra(0, N - 10, (i: int32) => { s.delete(key(i)); });
	let firstM: int32 = 0;
	for (const k of m.keys()) { firstM = k.id; break; }
	let firstS: int32 = 0;
	for (const k of s) { firstS = k.id; break; }
	return `compact map=${a} set=${b} sizes=${m.size},${s.size} first=${firstM},${firstS}`;
}

console.log(lookups());
console.log(grow());
console.log(compact());
