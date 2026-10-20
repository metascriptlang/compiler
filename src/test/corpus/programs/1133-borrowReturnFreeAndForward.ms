// @maxrss: 30
// @stdout: borrow-return-free 200000 9200000 4300000
struct Row { a: string; b: int32; }
class Box {
	items: Row[] = [];
	row(i: int32): Borrow<Row> { return this.items[i]; }
}
function firstRow(box: Box): Borrow<Row> { return box.items[0]; }
function viaView(box: Box, i: int32): Borrow<Row> { return box.row(i); }
function weigh(r: Row): int32 { return r.b + r.a.length; }
function show(r: Borrow<Row>): int32 { return r.b + r.a.length; }
const box = new Box();
box.items.push({ a: "first-padding-padding", b: 1 });
box.items.push({ a: "second-padding-padding", b: 2 });
let free = 0;
let forwarded = 0;
let viewed = 0;
for (let k = 0; k < 200000; k += 1) {
	free += firstRow(box).b;
	forwarded += weigh(box.row(k % 2)) + show(box.row(k % 2));
	viewed += viaView(box, k % 2).a.length;
}
console.log("borrow-return-free", free, forwarded, viewed);
