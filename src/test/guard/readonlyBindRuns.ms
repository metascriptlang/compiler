// A mutable array keeps binding mutable elements; a Readonly array's elements still read
//
// INVARIANT (ULTRALOCK V5, error E24): binding Readonly into the type parameter changes only a
//   Readonly receiver; Item[] still gives Item from find/at/map, and Readonly<Item[]> gives
//   readable Readonly<Item>.
//
// WHAT IT CATCHES: the Readonly binding leaking into a mutable receiver, or a read through the
//   Readonly result being refused.
//
// RED MEANS: the build fails, or a value below is wrong.
//
// GUARD-JS

class Item { v: int32 = 0; }

function mutate(items: Item[]): int32 {
	const x = items.find((y: Item): boolean => y.v == 2);
	if (x != null) x.v = 9;
	const z = items.at(0);
	z.v = 4;
	const m = items.map((y: Item) => y);
	m[0].v = 5;
	return z.v + m[0].v;
}

function read(items: Readonly<Item[]>): int32 {
	const x = items.find((y: Readonly<Item>): boolean => y.v == 9);
	const z = items.at(1);
	const m = items.map((y) => y.v);
	const i = items.findIndex((y) => y.v == 9) as int32;
	return (x == null ? 0 : x.v) + z.v + (m[0] as int32) + i;
}

function main(): int32 {
	const items: Item[] = [new Item(), new Item(), new Item()];
	items[1].v = 2;
	if (mutate(items) != 10) { throw "GUARD RED: mutable receiver"; }
	if (read(items) != 9 + 9 + 5 + 1) { throw "GUARD RED: readonly read"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
