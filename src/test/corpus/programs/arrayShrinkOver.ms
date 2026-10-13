// @exit: 1
// @stdout: value 5 not in range 0 .. 2
// @xfail(raiser): the Raiser VM reports the defect as its own 'raiser runtime error' on stderr, not the shared 'Error: ' line
class Item {
	id: int32 = 0;
	constructor(i: int32) { this.id = i; }
}

function count(n: int32): int32 {
	return n;
}

console.log("before");
const items: Item[] = [new Item(1), new Item(2)];
items.shrink(count(5));
console.log(`unreachable ${items.length}`);
