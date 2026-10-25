// @maxrss: 30
// @stdout: borrow-return-elements 7200000 4400000 500000
struct Row { a: string; b: int32; }
class Box {
	items: Row[] = [];
	names: string[] = [];
	nums: int32[] = [];
	row(i: int32): Borrow<Row> { return this.items[i]; }
	name(i: int32): Borrow<string> { return this.names[i]; }
	num(i: int32): Borrow<int32> { return this.nums[i]; }
}
const box = new Box();
for (let i = 0; i < 4; i += 1) {
	box.items.push({ a: `row-${i}-padding-padding`, b: i * 10 });
	box.names.push(`name-${i}-padding-padding`);
	box.nums.push(i + 1);
}
let structSum = 0;
let stringLen = 0;
let scalarSum = 0;
for (let k = 0; k < 200000; k += 1) {
	const i = k % 4;
	const r = box.row(i);
	structSum += r.b + r.a.length;
	stringLen += box.name(i).length;
	scalarSum += box.num(i);
	structSum += box.row(i).a.length * 0;
}
console.log("borrow-return-elements", structSum, stringLen, scalarSum);
