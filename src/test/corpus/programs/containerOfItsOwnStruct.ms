// @stdout: map 1 2 | hash 3 4 | pairs 5 6 | entries 7 8
// note: a struct holding a Map, a HashMap or a Vec whose element holds the struct by value compiles on C; the element struct is defined after the struct, as the container reaches it only through its payload. Before, C refused it (field has incomplete type).
struct MapNode { v: int32; kids: Map<string, MapNode>; }
struct HashNode { v: int32; kids: HashMap<string, HashNode>; }
struct PairNode { v: int32; pairs: Vec<[string, PairNode]>; }
struct EntryNode { v: int32; entries: Vec<Slot>; }
struct Slot { tag: int32; node: EntryNode; }

function main(): void {
	let m: MapNode = { v: 1, kids: new Map<string, MapNode>() };
	m.kids.set("a", { v: 2, kids: new Map<string, MapNode>() });
	const ma = m.kids.get("a");
	let h: HashNode = { v: 3, kids: new HashMap<string, HashNode>() };
	h.kids.set("b", { v: 4, kids: new HashMap<string, HashNode>() });
	const hb = h.kids.get("b");
	let p: PairNode = { v: 5, pairs: [] };
	p.pairs.push(["c", { v: 6, pairs: [] }]);
	let e: EntryNode = { v: 7, entries: [] };
	e.entries.push({ tag: 0, node: { v: 8, entries: [] } });
	console.log(`map ${m.v} ${ma != null ? ma.v : -1} | hash ${h.v} ${hb != null ? hb.v : -1} | pairs ${p.v} ${p.pairs[0][1].v} | entries ${e.v} ${e.entries[0].node.v}`);
}
main();
