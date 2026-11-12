// @stdout: a b c dt e7 ff gh ii
// note: a constructor owns a parameter only when its body moves it into an owning place. A local handed to `new` for the last time and kept only through an Unowned edge lives to the end of the caller's scope: stored directly, through a nested `new`, through a called function, through `super`, in a generic class, beside an owning store, and under a branch that does not own it.
class P { name: string; constructor(name: string) { this.name = name; } }

class Kid { up: Unowned<P> | null; constructor(up: P) { this.up = up; } }
class Tree { root: Kid; constructor(p: P) { this.root = new Kid(p); } }

class Linked { up: Unowned<P> | null = null; constructor(p: P) { link(this, p); } }
function link(l: Linked, p: P): void { l.up = p; }

class Base { up: Unowned<P> | null; constructor(p: P) { this.up = p; } }
class Derived extends Base {
	tag: string;
	constructor(p: P, tag: string) { super(p); this.tag = tag; }
}

class Slot<T> {
	value: T;
	up: Unowned<P> | null;
	constructor(value: T, p: P) { this.value = value; this.up = p; }
}

class Both { own: P; up: Unowned<P> | null; constructor(p: P) { this.own = p; this.up = p; } }

class Maybe {
	own: P | null = null;
	up: Unowned<P> | null;
	constructor(p: P, keep: boolean) {
		if (keep) this.own = p;
		this.up = p;
	}
}

function direct(): string {
	const p = new P("a");
	const k = new Kid(p);
	return k.up!.name;
}

function nested(): string {
	const p = new P("b");
	const t = new Tree(p);
	return t.root.up!.name;
}

function viaCall(): string {
	const p = new P("c");
	const l = new Linked(p);
	return l.up!.name;
}

function viaSuper(): string {
	const p = new P("d");
	const d = new Derived(p, "t");
	return d.up!.name + d.tag;
}

function generic(): string {
	const p = new P("e");
	const s = new Slot<int32>(7, p);
	return s.up!.name + s.value.toString();
}

function both(): string {
	const p = new P("f");
	const b = new Both(p);
	return b.own.name + b.up!.name;
}

function branch(): string {
	const p = new P("g");
	const lent = new Maybe(p, false);
	const q = new P("h");
	const kept = new Maybe(q, true);
	return lent.up!.name + kept.up!.name;
}

function escaped(): Both {
	const p = new P("i");
	return new Both(p);
}

function owned(): string {
	const b = escaped();
	return b.own.name + b.up!.name;
}

console.log([direct(), nested(), viaCall(), viaSuper(), generic(), both(), branch(), owned()].join(" "));
