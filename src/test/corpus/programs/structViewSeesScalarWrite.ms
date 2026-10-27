// @stdout: view-scalar 0 0 | nested 0 0 | held 0 0
struct Inner { n: int32; }
struct Row { a: string; inner: Inner; b: int32; }
class Box {
	items: Row[] = [];
	row(i: int32): Borrow<Row> { return this.items[i]; }
	setB(v: int32): void { this.items[0].b = v; }
	setInner(v: int32): void { this.items[0].inner.n = v; }
}
function scalarWrite(box: Box): string {
	const x = box.row(0);
	const before = x.b;
	box.setB(5);
	return before + " " + x.b;
}
function nestedWrite(box: Box): string {
	const x = box.row(0);
	const before = x.inner.n;
	box.setInner(7);
	return before + " " + x.inner.n;
}
function heldWrite(box: Box): string {
	const x = box.row(0);
	const before = x.b;
	box.items[0].b = 3;
	return before + " " + x.b;
}
const box = new Box();
box.items.push({ a: "xy", inner: { n: 0 }, b: 0 });
const r1 = scalarWrite(box);
box.items[0].b = 0;
const r2 = nestedWrite(box);
box.items[0].inner.n = 0;
const r3 = heldWrite(box);
console.log("view-scalar " + r1 + " | nested " + r2 + " | held " + r3);
