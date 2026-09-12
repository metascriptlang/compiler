// GUARD-JS
// A readonly field may be assigned through `this` inside the constructor of
// the class that declares it, TypeScript-style: with or without a declared
// default, on a plain class, a generic class, and a subclass assigning its own
// readonly field after super().
//
// A red guard means the declaring constructor lost its readonly exemption.

class Plain {
	readonly id: int32;
	readonly label: string = "default";
	constructor(id: int32) {
		this.id = id;
		this.label = "set-" + `${id}`;
	}
}

class Box<T> {
	readonly item: T;
	constructor(item: T) { this.item = item; }
	get(): T { return this.item; }
}

class Base {
	readonly base: int32 = 1;
}

class Derived extends Base {
	readonly own: int32;
	constructor() {
		super();
		this.own = this.base + 10;
	}
}

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	const p = new Plain(7);
	rc += expect(`${p.id}`, "7", "plainNoDefault");
	rc += expect(p.label, "set-7", "plainOverridesDefault");
	const b = new Box<int32>(21);
	rc += expect(`${b.get() * 2}`, "42", "genericCtor");
	const d = new Derived();
	rc += expect(`${d.own}`, "11", "derivedOwnField");
	if (rc == 0) { console.log("GUARD-OK readonlyCtorAssign"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
