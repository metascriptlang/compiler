// @stdout: 4
// @stdout: 3 5 502 a s 3
// note: destructuring an instance of a generic interface binds each name at the field type of that instance.
interface Box<S> {
	items: S[];
	count: int32;
	label: string;
}
class Item {
	n: int32;
	constructor(n: int32) { this.n = n; }
}
function size(b: Box<string>): int32 {
	const { items, count } = b;
	return count + (items.length as int32);
}
function open<S>(b: Box<S>): int32 {
	const { items, count } = b;
	return count + (items.length as int32);
}
function firstN(b: Box<Item>): int32 {
	const { items, count } = b;
	return items[0].n * 100 + count;
}
function rest(b: Box<string>): string {
	const { items, ...others } = b;
	return items[0] + " " + others.label + " " + others.count.toString();
}
const one: Box<string> = { items: ["a"], count: 3, label: "o" };
console.log(size(one).toString());
const bi: Box<Item> = { items: [new Item(5)], count: 2, label: "i" };
const bs: Box<string> = { items: ["a", "b"], count: 3, label: "s" };
console.log(open(bi).toString() + " " + open(bs).toString() + " " + firstN(bi).toString() + " " + rest(bs));
