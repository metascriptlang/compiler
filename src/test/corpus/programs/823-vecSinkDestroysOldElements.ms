class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}

function mkVec(n: int32): Vec<Item> {
	const v: Vec<Item> = [];
	for (let i: int32 = 0; i < n; i++) { v.push(new Item("i" + i.toString())); }
	return v;
}

function sinkFromCall(): void {
	let a: Vec<Item> = mkVec(2);
	a = mkVec(3);
	console.log(`sink ${a.length} ${a[2].name}`);
}

function copyFromLive(): void {
	let a: Vec<Item> = mkVec(2);
	const b: Vec<Item> = mkVec(1);
	a = b;
	console.log(`copy ${a.length} ${b.length} ${b[0].name}`);
}

function sinkInLoop(): void {
	let a: Vec<Item> = mkVec(1);
	for (let i: int32 = 0; i < 50; i++) { a = mkVec(4); }
	console.log(`loop ${a.length}`);
}

function mkNullable(n: int32): Vec<Item | null> {
	const v: Vec<Item | null> = [null];
	for (let i: int32 = 0; i < n; i++) { v.push(new Item("n" + i.toString())); }
	return v;
}

function sinkNullable(): void {
	let a: Vec<Item | null> = mkNullable(3);
	a = mkNullable(1);
	console.log(`nullable ${a.length}`);
}

sinkFromCall();
copyFromLive();
sinkInLoop();
sinkNullable();
