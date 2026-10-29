// @stdout: 3 6 9
// note: a struct that holds another by value, which holds a Vec of the first, releases the whole nest when its scope ends, whichever struct is lifted first and whichever is declared first; the empty destroy the first struct once got for its field leaked every deeper Vec.
struct EntryNode { v: int32; entries: Vec<Slot>; }
struct Slot { tag: int32; node: EntryNode; }

struct SlotB { tag: int32; node: NodeB; }
struct NodeB { v: int32; entries: Vec<SlotB>; }

function nodeFirst(): int32 {
	let e: EntryNode = { v: 1, entries: [] };
	e.entries.push({ tag: 1, node: { v: 2, entries: [{ tag: 2, node: { v: 3, entries: [] } }] } });
	return e.entries[0].node.entries[0].node.v;
}

function slotFirst(): int32 {
	let s: Slot = { tag: 0, node: { v: 4, entries: [] } };
	s.node.entries.push({ tag: 1, node: { v: 5, entries: [{ tag: 2, node: { v: 6, entries: [] } }] } });
	return s.node.entries[0].node.entries[0].node.v;
}

function slotFirstReversed(): int32 {
	let s: SlotB = { tag: 0, node: { v: 7, entries: [] } };
	s.node.entries.push({ tag: 1, node: { v: 8, entries: [{ tag: 2, node: { v: 9, entries: [] } }] } });
	return s.node.entries[0].node.entries[0].node.v;
}

console.log(`${nodeFirst()} ${slotFirst()} ${slotFirstReversed()}`);
