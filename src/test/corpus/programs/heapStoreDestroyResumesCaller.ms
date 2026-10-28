// @stdout: shrink 2 1
// @stdout: store 3 9 2
// @stdout: splice 2 a dddd
// @stdout: top 1
class Item { id: int32 = 0; constructor(i: int32) { this.id = i; } }
struct Slot { item: Item; tag: int32; }
struct Pair { name: string; n: int64; }

function fill(n: int32): Slot[] {
	const a: Slot[] = [];
	for (let i: int32 = 0; i < n; i++) {
		const s: Slot = { item: new Item(i), tag: i };
		a.push(s);
	}
	return a;
}

function run(): void {
	const a = fill(4);
	a.shrink(2);
	console.log(`shrink ${a.length} ${a[1].item.id}`);
	const b = fill(3);
	b[0] = { item: new Item(9), tag: 9 };
	console.log(`store ${b.length} ${b[0].item.id} ${b[2].tag}`);
	const p: Pair[] = [{ name: "a", n: 0 }, { name: "bb", n: 1 }, { name: "ccc", n: 2 }, { name: "dddd", n: 3 }];
	p.splice(1, 2);
	console.log(`splice ${p.length} ${p[0].name} ${p[1].name}`);
}
run();
const top = fill(3);
top.shrink(1);
console.log(`top ${top.length}`);
