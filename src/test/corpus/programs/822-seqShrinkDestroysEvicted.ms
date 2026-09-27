// @xfail(raiser): the Raiser VM's ArraySetLen rejects the float length the shrink computes ('expected an integer length, got kind Float')
class Item {
	id: int32 = 0;
	constructor(i: int32) { this.id = i; }
}

struct Slot { item: Item; tag: int32; }

function shiftAndShrinkClass(): void {
	const a: Item[] = [];
	for (let i: int32 = 0; i < 10; i++) { a.push(new Item(i)); }
	const first = a.shift();
	a.shift();
	console.log(`class shift ${first.id} len=${a.length} head=${a[0].id}`);
	a.setLength(3);
	console.log(`class shrink len=${a.length} last=${a[2].id}`);
	a.setLength(0);
	console.log(`class empty len=${a.length}`);
}

function shrinkStruct(): void {
	const a: Slot[] = [];
	for (let i: int32 = 0; i < 6; i++) {
		const s: Slot = { item: new Item(i), tag: i };
		a.push(s);
	}
	a.setLength(2);
	console.log(`struct shrink len=${a.length} last=${a[1].item.id}`);
}

shiftAndShrinkClass();
shrinkStruct();
