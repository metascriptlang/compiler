// @stdout: field=2 element=2 alias=2 global=2 captured=2 ctor=102 strings=outer
// note: an RC store evaluates its source before it reads the destination's old value, so a source that itself replaces the destination does not leave the store releasing a value already released. Before, C saved the old value first and released it twice (heap-use-after-free under ASan; the string-array field printed "index 0 out of bounds") while JS printed the values below. Covers a field, an array element, the destination reached through an alias, a module global, a local captured by a closure, a constructor that writes the destination, and a string-array field.

class Box {
	v: int32 = 0;
	constructor(v: int32) { this.v = v; }
}
class Holder { b: Box = new Box(0); }

function swapField(h: Holder, v: int32): Box {
	h.b = new Box(v);
	return h.b;
}
function viaField(): int32 {
	const h = new Holder();
	for (let i = 0; i < 3; i += 1) { h.b = swapField(h, i); }
	return h.b.v;
}

function swapElement(a: Box[], v: int32): Box {
	a[0] = new Box(v);
	return a[0];
}
function viaElement(): int32 {
	const a: Box[] = [new Box(0)];
	for (let i = 0; i < 3; i += 1) { a[0] = swapElement(a, i); }
	return a[0].v;
}

function viaAlias(): int32 {
	const h = new Holder();
	const other = h;
	for (let i = 0; i < 3; i += 1) { h.b = swapField(other, i); }
	return h.b.v;
}

let shared: Box = new Box(0);
function swapGlobal(v: int32): Box {
	shared = new Box(v);
	return shared;
}
function viaGlobal(): int32 {
	for (let i = 0; i < 3; i += 1) { shared = swapGlobal(i); }
	return shared.v;
}

function viaCaptured(): int32 {
	let x: Box = new Box(0);
	const swapX = (v: int32): Box => {
		x = new Box(v);
		return x;
	};
	for (let i = 0; i < 3; i += 1) { x = swapX(i); }
	return x.v;
}

class Slot { item: Tagged | null = null; }
class Tagged {
	v: int32 = 0;
	constructor(s: Slot, v: int32) {
		this.v = v + 100;
		s.item = null;
	}
}
function viaConstructor(): int32 {
	const s = new Slot();
	for (let i = 0; i < 3; i += 1) { s.item = new Tagged(s, i); }
	return s.item != null ? s.item.v : -1;
}

class Names { v: string[] = []; }
function refill(n: Names): string[] {
	n.v = ["inner" + String(n.v.length)];
	return ["outer"];
}
function viaStrings(): string {
	const n = new Names();
	n.v = ["first" + String(1)];
	n.v = refill(n);
	return n.v[0];
}

console.log(`field=${viaField()} element=${viaElement()} alias=${viaAlias()} global=${viaGlobal()} captured=${viaCaptured()} ctor=${viaConstructor()} strings=${viaStrings()}`);
