struct Bag { keys: string[]; }

function getDynamicField(this b: Bag, key: string): string { return key + "@" + String(b.keys.length); }

class Reader<T> {
	item: T;
	constructor(x: T) { this.item = x; }
	color(): string { return this.item.color; }
}

class Other<T> {
	item: T;
	constructor(x: T) { this.item = x; }
}

test "a type argument that declares getDynamicField still reads through it beside another instance" {
	assert new Other<int32>(1).item == 1;
	assert new Reader<Bag>({ keys: ["a", "b"] }).color() == "color@2";
}
