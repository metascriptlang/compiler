// Parity program — a key whose own `hash` returns 0 is still found, overwritten and counted once
// in Map, Set, HashMap and HashSet, before and after the table grows: a zero hash is remapped where
// the table takes it, not only inside the std hashes, so it never reads as an empty slot.
//
// @stdout: map=true,0,100 set=true,100 hashmap=true,7,100 hashset=true,100
// @exit: 0

struct Key { id: int32; }
export function `==`(x: Key, y: Key): boolean { return x.id == y.id; }
export function hash(this k: Key): int64 { return k.id as int64; }

const m = new Map<Key, int32>();
const s = new Set<Key>();
const hm = new HashMap<Key, int32>();
const hs = new HashSet<Key>();
for (let i: int32 = 0; i < 100; i += 1) {
	const k: Key = { id: i };
	m.set(k, i);
	s.add(k);
	hm.set(k, i);
	hs.add(k);
}
const zero: Key = { id: 0 };
hm.set(zero, 7);
console.log(`map=${m.has(zero)},${m.get(zero) ?? -1},${m.size} set=${s.has(zero)},${s.size} hashmap=${hm.has(zero)},${hm.get(zero) ?? -1},${hm.size} hashset=${hs.has(zero)},${hs.size}`);
