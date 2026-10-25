import { compileToC } from "../helpers";

function elementHookCalls(c: string, typePrefix: string, op: string = ""): int32 {
	let n: int32 = 0;
	for (const line of c.split("\n")) {
		const t = line.trim();
		if (t.startsWith(typePrefix) && t.contains(op + "((&(") && (t.contains("msArrayAccess(") || t.contains("["))) n++;
	}
	return n;
}

test "a vector of plain-data structs destroys and copies its payload without an element loop" {
	const result = compileToC(`
struct P { x: int32; y: int32 }
struct Pair<A, B> { a: A; b: B }
struct Holder { ps: Vec<P>; pairs: Vec<Pair<int32, int32>>; tag: int32 }
struct Named { name: string; n: int32 }
struct Roster { people: Vec<Named> }
function run(n: int32): int32 {
	let a: Holder = { ps: [], pairs: [], tag: 1 };
	for (let i: int32 = 0; i < n; i++) { a.ps.push({ x: i, y: i }); a.pairs.push({ a: i, b: i }); }
	let b: Holder = { ps: [], pairs: [], tag: 2 };
	b = a;
	let r: Roster = { people: [] };
	r.people.push({ name: "a" + n.toString(), n: n });
	let s: Roster = { people: [] };
	s = r;
	return b.ps.length + b.pairs.length + s.people.length;
}
console.log(run(3));
`);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.value;
	assert elementHookCalls(c, "P__") == 0, "P element hook called in a loop";
	assert elementHookCalls(c, "Pair_") == 0, "Pair element hook called in a loop";
	assert c.contains("msArrayCopyPayload((*dest).ps, (*src).ps);"), "Vec<P> bulk copy";
	assert c.contains("msArrayCopyPayload((*dest).pairs, (*src).pairs);"), "Vec<Pair> bulk copy";
	assert elementHookCalls(c, "Named__", "Destroy") > 0, "string-field element keeps its destroy loop";
	assert elementHookCalls(c, "Named__", "Copy") > 0, "string-field element keeps its copy loop";
}

test "a vector of numbers in a struct copies into the destination's payload" {
	const result = compileToC(`
struct Nums { xs: Vec<int32> }
let a: Nums = { xs: [1, 2, 3] };
let b: Nums = { xs: [4, 5, 6, 7] };
b = a;
console.log(b.xs.length);
`);
	assert result.ok, result.ok ? "" : result.error;
	assert result.value.contains("msArraySetLen((*dest).xs, (*src).xs);"), "reuses the destination payload";
	assert result.value.contains("msArrayCopyPayload((*dest).xs, (*src).xs);"), "bulk copy";
}

test "a map-shaped class of numbers destroys its entries without an element loop; a string key keeps it" {
	const result = compileToC(`
struct Entry<K, V> { hcode: int64; key: K; value: V; }
struct Slot<T> { hcode: int64; key: T; }
class Table<K, V> { entries: Vec<Entry<K, V>> = []; }
class Bag<T> { slots: Vec<Slot<T>> = []; }
const m = new Table<int32, int32>();
m.entries.push({ hcode: 1, key: 1, value: 2 });
m.entries = [];
const s = new Bag<number>();
s.slots.push({ hcode: 1, key: 1 });
const k = new Table<string, int32>();
k.entries.push({ hcode: 1, key: "a", value: 1 });
console.log(m.entries.length + s.slots.length + k.entries.length);
`);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.value;
	assert elementHookCalls(c, "Entry_", "__int32_int32Destroy") == 0, "Table<int32, int32> entries";
	assert elementHookCalls(c, "Slot_", "__float64Destroy") == 0, "Bag<number> slots";
	assert elementHookCalls(c, "Entry_", "__string_int32Destroy") > 0, "the string-keyed table keeps its destroy loop";
}
