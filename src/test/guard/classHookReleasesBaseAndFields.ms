// nim-guard: a class's onDestroy is followed by its base class's release and then its own fields.
//
// Nim: liftdestructors.nim fillBodyObjTImpl releases the base before the object's own fields;
// a user '=destroy' replaces the lifted body. A class here keeps the deinit order instead (a forced
// divergence: the author can no longer call a base hook or release a field by hand): the class's
// hook, then the base part (base hook, base fields), then its own fields. The hook is called as
// the routine itself (Nim transf.nim procCall), never through the override dispatcher.
//
// RED MEANS the hook again replaces the base and the fields: on the parent the Child prints only
// its own hook and leaks three HookedTag, the Plain leaks its base HookedTag, and once the base
// part runs through the dispatcher the Child's hook runs twice.
//
// GUARD-BALANCE HookedTag

import { exit } from "std/process";

let events: string[] = [];

class HookedTag {
	name: string;
	constructor(name: string) { this.name = name; }
	onDestroy(): void { events.push(`field ${this.name}`); }
}

class Base {
	baseTag: HookedTag;
	constructor() { this.baseTag = new HookedTag("base"); }
	onDestroy(): void { events.push(`hook base sees ${this.baseTag.name}`); }
}

class Mid extends Base {
	midTag: HookedTag;
	constructor() { super(); this.midTag = new HookedTag("mid"); }
}

class Child extends Mid {
	ownTag: HookedTag;
	constructor() { super(); this.ownTag = new HookedTag("own"); }
	onDestroy(): void { events.push(`hook child sees ${this.ownTag.name}`); }
}

class Plain extends Base {
	plainTag: HookedTag;
	constructor() { super(); this.plainTag = new HookedTag("plain"); }
}

function child(): void { const c = new Child(); }
function plain(): void { const p = new Plain(); }
function heldAsBase(): void { const b: Base = new Child(); }

function expect(run: () => void, want: string): void {
	events = [];
	run();
	const got = events.join(", ");
	console.log(got);
	if (got != want) exit(1);
}

expect(child, "hook child sees own, hook base sees base, field base, field own, field mid");
expect(plain, "field plain, hook base sees base, field base");
expect(heldAsBase, "hook child sees own, hook base sees base, field base, field own, field mid");
console.log("GUARD-OK");
