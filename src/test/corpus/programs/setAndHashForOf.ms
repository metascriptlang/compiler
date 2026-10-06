// @stdout: set=1,3 hashset=12 hashmap=x7 mapkeys=b,c mapvalues=2,3 struct=10 captured=b2c3 generator=0,2,4|closed
// note: a for-of over a Set, a HashSet and a HashMap ranges them through their generators, as one over a Map does; on the Raiser those generators run as the state machine C runs (before, the Raiser stopped at the first `yield`). keys() and values() are arrays and range as arrays.
struct Pt { x: int32; y: int32; }
const set = new Set<int32>();
set.add(1);
set.add(2);
set.add(3);
set.delete(2);
const setSeen: string[] = [];
for (const v of set) setSeen.push(v.toString());
const hs = new HashSet<int32>();
hs.add(5);
hs.add(7);
let hsSum: int32 = 0;
for (const v of hs) hsSum += v;
const hm = new HashMap<string, int32>();
hm.set("x", 7);
let hmSeen = "";
for (const [k, v] of hm) hmSeen = hmSeen + k + v.toString();
const m = new Map<string, int32>();
m.set("a", 1);
m.set("b", 2);
m.set("c", 3);
m.delete("a");
const pts = new Map<int32, Pt>();
pts.set(1, { x: 2, y: 3 });
pts.set(2, { x: 1, y: 2 });
let area: int32 = 0;
for (const [id, p] of pts) area += id * p.x * p.y;
const later: (() => string)[] = [];
for (const [k, v] of m) later.push(() => k + v.toString());
let captured = "";
for (const f of later) captured = captured + f();
function* evens(limit: int32): Iterator<int32> {
	let i: int32 = 0;
	try {
		while (i < limit) {
			if (i % 2 == 1) { i += 1; continue; }
			yield i;
			i += 1;
		}
	} finally {
		closed = "closed";
	}
}
let closed = "open";
const evenSeen: string[] = [];
for (const e of evens(5)) evenSeen.push(e.toString());
console.log("set=" + setSeen.join(",") + " hashset=" + hsSum.toString() + " hashmap=" + hmSeen
	+ " mapkeys=" + m.keys().join(",") + " mapvalues=" + m.values().map((v: int32): string => v.toString()).join(",")
	+ " struct=" + area.toString() + " captured=" + captured + " generator=" + evenSeen.join(",") + "|" + closed);
