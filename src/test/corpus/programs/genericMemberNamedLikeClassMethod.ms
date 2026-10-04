// @stdout: rex|color@2|wrapped rex woofs
// @exit: 0

// A member of a type argument named like the generic class's own method is that member, per instance.

struct Pet { label: string; }

struct Bag { keys: string[]; }

function getDynamicField(this b: Bag, key: string): string { return key + "@" + String(b.keys.length); }

struct Dog { name: string; }

function speak(this d: Dog): string { return d.name + " woofs"; }

class Tag<T> {
	item: T;
	constructor(x: T) { this.item = x; }
	label(): string { return this.item.label; }
}

class Reader<T> {
	item: T;
	constructor(x: T) { this.item = x; }
	color(): string { return this.item.color; }
}

class Wrapper<T> {
	item: T;
	constructor(x: T) { this.item = x; }
	speak(): string { return "wrapped " + this.item.speak(); }
}

const tag = new Tag<Pet>({ label: "rex" }).label();
const read = new Reader<Bag>({ keys: ["a", "b"] }).color();
const wrapped = new Wrapper<Dog>({ name: "rex" }).speak();
console.log(`${tag}|${read}|${wrapped}`);
