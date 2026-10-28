// @maxrcops: 410000
// @stdout: infer-sink 20000 20000 20000 20000 10000 20000 20000 20000 20000 20000
// note: a routine that unconditionally stores, wraps or forwards a parameter to a sink takes it as sink, so each caller moves its last use in and the callee stores without a copy; a conditional store, a read after the call and a routine used as a value stay borrowed and copy.

class Item {
	id: int32 = 0;
}
class Box {
	items: Item[] = [];
}
class Holder {
	item: Item = new Item();
}
class Keeper {
	item: Item = new Item();
	keep(it: Item): void { this.item = it; }
}
class Shelf {
	items: Item[] = [];
	put(it: Item): void { this.items.push(it); }
}
class Crate extends Shelf {
	put(it: Item): void { this.items.push(it); }
}
struct Slot { item: Item; n: int32 }

function make(k: int32): Item {
	const it = new Item();
	it.id = k;
	return it;
}
function takeOwned(b: Box, sink it: Item): void { b.items.push(it); }
function stored(b: Box, it: Item): void { b.items.push(it); }
function setItem(h: Holder, it: Item): void { h.item = it; }
function wrapped(it: Item): Item[] { return [it]; }
function slotOf(it: Item): Slot { return { item: it, n: 1 }; }
function relayed(b: Box, it: Item): void { takeOwned(b, it); }
function maybe(b: Box, it: Item, keep: boolean): void {
	if (keep) b.items.push(it);
}
function viaValue(b: Box, it: Item): void { b.items.push(it); }

const box = new Box();
const holder = new Holder();
const asValue: (b: Box, it: Item) => void = viaValue;
let nStored = 0;
let nField = 0;
let nWrapped = 0;
let nSlot = 0;
let nMaybe = 0;
let nRelayed = 0;
let nAgain = 0;
let nValue = 0;
let nMethod = 0;
let nOverride = 0;
const keeper = new Keeper();
const shelf: Shelf = new Crate();
for (let k = 0; k < 20000; k++) {
	stored(box, make(k));
	nStored += box.items.pop()!.id == k ? 1 : 0;
	setItem(holder, make(k));
	nField += holder.item.id == k ? 1 : 0;
	nWrapped += wrapped(make(k))[0].id == k ? 1 : 0;
	nSlot += slotOf(make(k)).item.id == k ? 1 : 0;
	maybe(box, make(k), k % 2 == 0);
	if (k % 2 == 0) nMaybe += box.items.pop()!.id == k ? 1 : 0;
	relayed(box, make(k));
	nRelayed += box.items.pop()!.id == k ? 1 : 0;
	const again = make(k);
	stored(box, again);
	nAgain += again.id == k && box.items.pop()!.id == k ? 1 : 0;
	keeper.keep(make(k));
	nMethod += keeper.item.id == k ? 1 : 0;
	shelf.put(make(k));
	nOverride += shelf.items.pop()!.id == k ? 1 : 0;
	asValue(box, make(k));
	nValue += box.items.pop()!.id == k ? 1 : 0;
}
console.log(`infer-sink ${nStored} ${nField} ${nWrapped} ${nSlot} ${nMaybe} ${nRelayed} ${nAgain} ${nValue} ${nMethod} ${nOverride}`);
