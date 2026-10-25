// @stdout: append-during-read direct=54 directBig=55 callback=108 callbackBig=114 items=388 bigs=388
class Item { v: int32 = 0; tag: string = ""; }

struct Big { item: Item; a: int64; b: int64; c: int64; }

const items: Item[] = [];
const bigs: Big[] = [];

function growItemsThenRead(x: Item): int32 {
	for (let k = 0; k < 64; k++) items.push(new Item());
	return x.tag.length as int32;
}

function growBigsThenRead(x: Big): int32 {
	for (let k = 0; k < 64; k++) bigs.push({ item: new Item(), a: 0, b: 0, c: 0 });
	return x.item.tag.length as int32 + x.a as int32;
}

function eachItem(xs: Item[], n: int32, cb: (x: Item) => int32): int32 {
	let total: int32 = 0;
	for (let i = 0; i < n; i++) total += cb(xs[i]);
	return total;
}

function eachBig(xs: Big[], n: int32, cb: (x: Big) => int32): int32 {
	let total: int32 = 0;
	for (let i = 0; i < n; i++) total += cb(xs[i]);
	return total;
}

for (let i = 0; i < 4; i++) {
	const it = new Item();
	it.v = i as int32;
	it.tag = `item-${"z".repeat(20)}-${i}`;
	items.push(it);
	bigs.push({ item: it, a: i as int64, b: 0, c: 0 });
}
let direct: int32 = 0;
for (let i = 0; i < 2; i++) direct += growItemsThenRead(items[i]);
let directBig: int32 = 0;
for (let i = 0; i < 2; i++) directBig += growBigsThenRead(bigs[i]);
const callback = eachItem(items, 4, (x: Item): int32 => {
	for (let k = 0; k < 64; k++) items.push(new Item());
	return x.tag.length as int32;
});
const callbackBig = eachBig(bigs, 4, (x: Big): int32 => {
	for (let k = 0; k < 64; k++) bigs.push({ item: new Item(), a: 0, b: 0, c: 0 });
	return x.item.tag.length as int32 + x.a as int32;
});
console.log(`append-during-read direct=${direct} directBig=${directBig} callback=${callback} callbackBig=${callbackBig} items=${items.length} bigs=${bigs.length}`);
