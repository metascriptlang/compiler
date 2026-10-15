class Item {
	id: int32 = 0;
	constructor(i: int32) { this.id = i; }
}

function cut<T>(a: T[], n: int64): void {
	a.shrink(n);
}

const items: Item[] = [new Item(1), new Item(2), new Item(3), new Item(4)];
items.shrink(3);
cut(items, 3);
console.log(`items ${items.length} last=${items[2].id}`);
cut(items, 1);
console.log(`items ${items.length} first=${items[0].id}`);
items.shrink(0);
console.log(`items ${items.length}`);

const nums: int32[] = [5, 6, 7];
nums.shrink(2);
const names: string[] = ["a", "b", "c"];
cut(names, 1);
console.log(`nums ${nums.length} ${nums[1]} names ${names.length} ${names[0]}`);
