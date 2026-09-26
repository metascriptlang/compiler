// @stdout: init 42 1 | shelf 2 5 | spawn 1 0
import { Shelf } from "./box";

class Box<T> {
	tag: string = "init";
	n: int32 = 42;
	items: T[] = [];
}

class Item {
	w: int32 = 5;
}

class Pool<T> {
	name: string = "spawn";
	slots: T[] = [];
	fresh(): Pool<T> { return new Pool<T>(); }
}

function run(): void {
	const b = new Box<string>();
	b.items.push("x");
	const s = new Shelf<Item>();
	s.add(new Item());
	s.add(new Item());
	const p = new Pool<int32>();
	const q = p.fresh();
	q.slots.push(3);
	console.log(b.tag + " " + b.n.toString() + " " + b.items.length.toString()
		+ " | " + s.label + " " + s.items.length.toString() + " " + s.items[1].w.toString()
		+ " | " + q.name + " " + q.slots.length.toString() + " " + p.slots.length.toString());
}

run();
