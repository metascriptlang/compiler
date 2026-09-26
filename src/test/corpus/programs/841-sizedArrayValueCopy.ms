// @xfail(raiser): output differs from c: a T[N] copy aliases its source (c3 c3, f6 i3 twice)
class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}

struct Holder {
	names: string[2];
	items: Item[2];
}

function mk(s: string, i: int32): string {
	return s + i.toString() + "-long-enough-to-be-heap-allocated-for-sure";
}

function churn(): number {
	const junk: string[] = [];
	for (let i: int32 = 0; i < 50; i += 1) { junk.push(mk("z", i)); }
	return junk.length;
}

function locals(): void {
	const a: string[2] = [mk("a", 1), mk("b", 2)];
	let b: string[2] = a;
	b[0] = mk("c", 3);
	churn();
	console.log(a[0]);
	console.log(b[0]);
}

function fields(): void {
	const h: Holder = { names: [mk("d", 4), mk("e", 5)], items: [new Item("i1"), new Item("i2")] };
	let g: Holder = h;
	g.names[1] = mk("f", 6);
	g.items[0] = new Item("i3");
	churn();
	console.log(h.names[1] + " " + h.items[0].name);
	console.log(g.names[1] + " " + g.items[0].name);
}

locals();
fields();
