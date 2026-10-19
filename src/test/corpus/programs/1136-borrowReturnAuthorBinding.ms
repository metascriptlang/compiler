// @maxrss: 30
// @stdout: borrow-return-author-binding 21177780 first-padding-padding|0|z|21 first-padding-padding|1|z
struct Row { a: string; b: int32; }
class Box {
	items: Row[] = [];
	at(i: int32): Borrow<Row> { return this.items[i]; }
	bump(): void { this.items[0].b += 1; }
}
function afterBump(box: Box, other: Row): string {
	let x = box.at(0);
	box.bump();
	const y = x;
	const xa = x.a;
	x = other;
	return `${y.a}|${y.b}|${x.a}|${xa.length}`;
}
function afterReassign(box: Box, other: Row): string {
	let x = box.at(0);
	const y = x;
	x = other;
	return `${y.a}|${y.b}|${x.a}`;
}
const box = new Box();
box.items.push({ a: "first-padding-padding", b: 0 });
let total = 0;
for (let k = 0; k < 200000; k += 1) {
	const other: Row = { a: `other-${k}-padding-padding`, b: k };
	const s = afterBump(box, other);
	const t = afterReassign(box, other);
	total += s.length + t.length;
	box.items[0].b = 0;
}
console.log("borrow-return-author-binding", total, afterBump(box, { a: "z", b: 1 }), afterReassign(box, { a: "z", b: 1 }));
