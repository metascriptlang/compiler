import { Cell, wrap, hitCount } from "../lib/cell";

class Item {
	name: string = "i";
}

class Tag {
	label: string = "t";
}

export function run(): int32 {
	const items = new Map<string, Item>();
	items.set("a", new Item());
	const tags = new Map<string, Tag>();
	tags.set("t", new Tag());
	const tag = wrap(new Tag());
	const c = wrap(new Cell<int32>(5).get());
	return (c.get() + hitCount() + items.size + tags.size + tag.get().label.length) as int32;
}
