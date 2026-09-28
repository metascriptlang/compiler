class Item {
	id: int32 = 0;
	constructor(i: int32) { this.id = i; }
}

struct Pair { name: string; n: int64; }

function spliceInt32(): void {
	const a: int32[] = [10, 20, 30, 40, 50];
	a.splice(1, 2);
	console.log(`int32 ${a.length} ${a[0]} ${a[1]} ${a[2]}`);
}

function spliceInt64(): void {
	const a: int64[] = [1, 2, 3, 4, 5, 6];
	a.splice(1, 2);
	a.splice(10, 1);
	a.splice(2, 99);
	console.log(`int64 ${a.length} ${a[0]} ${a[1]}`);
}

function spliceBool(): void {
	const a: boolean[] = [true, false, true];
	a.splice(0, 1);
	console.log(`bool ${a.length} ${a[0]} ${a[1]}`);
}

function spliceStruct(): void {
	const a: Pair[] = [];
	for (let i: int32 = 0; i < 4; i++) {
		const p: Pair = { name: "s".repeat(i + 1), n: i as int64 };
		a.push(p);
	}
	a.splice(1, 2);
	console.log(`struct ${a.length} ${a[0].name} ${a[1].name} ${a[1].n}`);
}

function spliceClass(): void {
	const a: Item[] = [new Item(1), new Item(2), new Item(3), new Item(4)];
	a.splice(1, 2);
	a.splice(3, 1);
	console.log(`class ${a.length} ${a[0].id} ${a[1].id}`);
}

spliceInt32();
spliceInt64();
spliceBool();
spliceStruct();
spliceClass();
