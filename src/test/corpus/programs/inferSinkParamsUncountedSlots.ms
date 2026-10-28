// @maxrcops: 170000
// @stdout: uncounted 20000 20000 20000 20000 20000
// note: a parameter stored only into a slot that holds no count (a cursor field, a cursor array, a raw pointer field) stays borrowed, because a store there takes no ownership; inferring sink would add an incref at the call and a decref at the callee's exit for nothing, and on values read by several threads that traffic races.

class Item {
	id: int32 = 0;
}
class Holder {
	item: Item = new Item();
}
interface Frame {
	node: Cursor<Item>;
	depth: int32;
}
class Walk {
	at: Cursor<Item> | null = null;
	seen: Cursor<Item>[] = [];
}

function frameOf(it: Item): Frame { return { node: it, depth: 1 }; }
function visit(w: Walk, it: Item): void { w.at = it; }
function remember(w: Walk, it: Item): void { w.seen.push(it); }
function pair(it: Item): Cursor<Item>[] { return [it, it]; }
function mark(w: Walk, it: Item): int32 { w.seen = [it]; return w.seen.length; }

const holder = new Holder();
const walk = new Walk();
let nFrame = 0;
let nVisit = 0;
let nRemember = 0;
let nPair = 0;
let nMark = 0;
for (let k = 0; k < 20000; k++) {
	holder.item.id = k;
	nFrame += frameOf(holder.item).node.id == k ? 1 : 0;
	visit(walk, holder.item);
	nVisit += walk.at!.id == k ? 1 : 0;
	remember(walk, holder.item);
	nRemember += walk.seen[walk.seen.length - 1].id == k ? 1 : 0;
	walk.seen = [];
	nPair += pair(holder.item)[1].id == k ? 1 : 0;
	nMark += mark(walk, holder.item);
}
console.log(`uncounted ${nFrame} ${nVisit} ${nRemember} ${nPair} ${nMark}`);
