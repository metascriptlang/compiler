// @stdout: rest=4 2 6
class Item {
	v: int32 = 0;
	constructor(v: int32) { this.v = v; }
}
interface Leaf { v: string; }
function mk(v: int32): Item { return new Item(v); }
function items(): Item[] {
	const base: Item[] = [mk(1), mk(2)];
	const more: Item[] = [...base, mk(3)];
	return more.length == 3 && base.length == 2 ? more : base;
}
function leaves(): string {
	const base: Leaf[] = [{ v: "p" }, { v: "q" }];
	const more: Leaf[] = [...base, { v: "r" }];
	return base[0].v + more[0].v + more[2].v;
}
function words(flag: boolean): string {
	const a: string[] = ["a" + "1", "b" + "2"];
	const b: string[] = flag ? [...a, "c3"] : [...a];
	return a.join(",") + "|" + b.join(",");
}
function rest(): string {
	const base: Item[] = [mk(4), mk(5), mk(6)];
	const [first, ...others] = base;
	return first.v.toString() + " " + others.length.toString() + " " + base[2].v.toString();
}
function run(): void {
	let total = 0;
	for (let i = 0; i < 3; i += 1) {
		for (const it of items()) total += it.v;
	}
	console.log("items=" + total.toString());
	console.log("leaves=" + leaves());
	console.log("words=" + words(true) + " " + words(false));
	console.log("rest=" + rest());
}
run();
