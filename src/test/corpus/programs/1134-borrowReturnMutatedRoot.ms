// @maxrss: 30
// @stdout: borrow-return-mutated 3600000 0 200000
struct Row { a: string; b: int32; }
class Box {
	items: Row[] = [];
	row(i: int32): Borrow<Row> { return this.items[i]; }
	bump(): void { this.items[0].b += 1; }
}
function readKept(box: Box): int32 {
	const x = box.row(0);
	return x.b + x.a.length;
}
function readMutated(box: Box): int32 {
	const x = box.row(0);
	box.bump();
	return x.b;
}
function readOverwritten(box: Box): int32 {
	const x = box.row(0);
	box.items[0].b = 1000;
	return x.b;
}
const box = new Box();
box.items.push({ a: "xy-padding-padding", b: 0 });
let kept = 0;
let mutated = 0;
let overwritten = 0;
for (let k = 0; k < 200000; k += 1) {
	kept += readKept(box);
	mutated += readMutated(box);
	overwritten += readOverwritten(box);
	box.items[0].b = 0;
}
console.log("borrow-return-mutated", kept, mutated, overwritten);
