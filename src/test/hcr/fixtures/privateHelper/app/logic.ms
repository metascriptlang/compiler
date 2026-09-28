import { Cell, wrap, hitCount } from "../lib/cell";

class Item {
	name: string = "i";
}

export function run(): int32 {
	const items = new Map<string, Item>();
	items.set("a", new Item());
	const c = wrap(new Cell<int32>(5).get());
	return (c.get() + hitCount() + items.size) as int32;
}
