// @stdout: 5 2 7 9 11 2 | 4 8 1
// note: a generic instance stored in a generic of another module keeps its type arguments
// (fixedbugs/bug553). The container's body is re-checked in its own module, where `Crate` names the
// caller's declaration through an alias of that name; that alias dropped `<int32>`, so C declared the
// entry vector under two names (interface, class) or the check refused `set` (value struct).

import { Bag } from "./genericBagLib";

interface Crate<T> { v: T; }
class Bin<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
struct Cell<T> { v: T; }
type Boxed<T> = Crate<T>;

function stdMaps(): string {
	const hm = new HashMap<string, Crate<int32> >();
	const c: Crate<int32> = { v: 5 as int32 };
	hm.set("a", c);
	hm.set("b", { v: 6 as int32 });
	const om = new Map<string, Crate<int32> >();
	om.set("x", { v: 7 as int32 });
	const bins: HashMap<string, Bin<int32>> = new HashMap<string, Bin<int32> >();
	bins.set("p", new Bin<int32>(9 as int32));
	const cells = new HashMap<string, Cell<int32> >();
	cells.set("q", { v: 3 as int32 });
	const boxes = new HashMap<string, Boxed<int32> >();
	boxes.set("r", { v: 11 as int32 });
	const ha = hm.get("a");
	const ox = om.get("x");
	const bp = bins.get("p");
	const br = boxes.get("r");
	if (ha == null || ox == null || bp == null || br == null) return "missing";
	return `${ha.v} ${hm.size} ${ox.v} ${bp.v} ${br.v} ${om.size + cells.size}`;
}

function userBag(): string {
	const b = new Bag<Crate<int32> >();
	b.add({ v: 4 as int32 });
	const n = new Bag<Bin<int32> >();
	n.add(new Bin<int32>(8 as int32));
	return `${b.first().v} ${n.first().v} ${b.items.length}`;
}

function main(): void {
	console.log(`${stdMaps()} | ${userBag()}`);
}

main();
