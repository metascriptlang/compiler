// Parity program — a key type's `hash` and `==` that are not exported still reach the std Map, Set,
// HashMap and HashSet instantiated in the same module, on every backend: an equal key overwrites,
// is found and is counted once. Both private (flat `==`), and an exported hash with a private
// receiver-form `==`.
//
// @stdout: map=1,2 set=1,true hashmap=1,2 hashset=1,true
// @exit: 0

struct Line { text: string; runs: Vec<int32>; }
function hash(this l: Line): int64 { return l.text.length as int64; }
function `==`(a: Line, b: Line): boolean { return a.text == b.text; }

struct Tag { name: string; n: int32; }
export function hash(this t: Tag): int64 { return t.name.length as int64; }
function `==`(this a: Tag, b: Tag): boolean { return a.name == b.name; }

const m = new Map<Line, int32>();
m.set({ text: "a", runs: [] }, 1);
m.set({ text: "a", runs: [3] }, 2);
const s = new Set<Line>();
s.add({ text: "ab", runs: [] });
s.add({ text: "ab", runs: [1] });
const hm = new HashMap<Tag, int32>();
hm.set({ name: "t", n: 1 }, 1);
hm.set({ name: "t", n: 2 }, 2);
const hs = new HashSet<Tag>();
hs.add({ name: "u", n: 1 });
hs.add({ name: "u", n: 2 });
console.log(`map=${m.size},${m.get({ text: "a", runs: [] }) ?? -1} set=${s.size},${s.has({ text: "ab", runs: [] })} hashmap=${hm.size},${hm.get({ name: "t", n: 9 }) ?? -1} hashset=${hs.size},${hs.has({ name: "u", n: 9 })}`);
