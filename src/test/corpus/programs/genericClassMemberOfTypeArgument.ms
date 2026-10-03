// @stdout: rex|7|rex/rex
// @exit: 0

// A generic class body resolves a member of its type argument per instance.

struct Pet { name: string; }

function accountKind(this typeof Pet): int32 { return 7; }

class Holder<T> {
	item: T;
	constructor(x: T) { this.item = x; }
	label(): string { return this.item.name; }
	kind(): int32 { return T.accountKind(); }
}

class Outer<T> {
	inner: Holder<T>;
	constructor(x: T) { this.inner = new Holder<T>(x); }
	label(): string { return this.inner.item.name + "/" + this.inner.label(); }
}

const pet = new Holder<Pet>({ name: "rex" });
const outer = new Outer<Pet>({ name: "rex" });
console.log([pet.label(), String(pet.kind()), outer.label()].join("|"));
