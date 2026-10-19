// @maxrss: 30
// @stdout: borrow-return-generic 2900000 2800000 600000
struct Row { a: string; b: int32; }
class List<T> {
	items: T[] = [];
	at(i: number): Borrow<T> { return this.items[i]; }
}
const rows = new List<Row>();
const names = new List<string>();
const nums = new List<number>();
for (let i = 0; i < 4; i += 1) {
	rows.items.push({ a: `row-${i}-padding`, b: i });
	names.items.push(`name-${i}-padding`);
	nums.items.push(i * 2);
}
let a = 0;
let b = 0;
let c: number = 0;
for (let k = 0; k < 200000; k += 1) {
	const i = k % 4;
	a += rows.at(i).b + rows.at(i).a.length;
	b += names.at(i).length;
	c += nums.at(i);
}
console.log("borrow-return-generic", a, b, c);
