// nim-guard: overwriting a variable stores the new value before it releases the old one, so an
// onDestroy run by the release that reads the variable finds the new value, never the dying one.
//
// Nim stores first only for a type that can form a cycle (liftdestructors.nim atomicRefOp and
// atomicClosureOp, isCyclic branch) and releases first for every other ref and object field;
// NIM-REF records the forced divergence, because releasing first let such a hook read freed
// memory (ASan heap-use-after-free on MS and on the Nim 2.2.2 twin under arc and orc).
//
// RED MEANS an overwrite of that shape releases the old value while the destination still names
// it: the hook read its own tag (1) instead of the new value's (2), or crashed.

class Witness {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void {
		if (watching) {
			watching = false;
			seen = readWatched(reading);
		}
	}
}

class Holder {
	w: Witness | null;
	constructor(w: Witness | null) { this.w = w; }
}

class Link {
	next: Link | null = null;
	w: Witness | null;
	constructor(w: Witness | null) { this.w = w; }
}

struct Slot {
	w: Witness | null;
}

struct Outer {
	inner: Slot;
}

let watching = false;
let seen: int32 = 0;
let failures = "";
let reading = "";

function tagOf(w: Witness | null): int32 {
	return w == null ? -2 : w.tag;
}

function eitherTag(e: Witness | string): int32 {
	if (typeof e === "string") return -2;
	return e.tag;
}

function watch(what: string): void {
	reading = what;
	seen = 0;
	watching = true;
}

function check(what: string): void {
	watching = false;
	if (seen != 2) failures = `${failures}${what}: the hook read ${seen}, want 2; `;
}

let holder: Holder = new Holder(null);
let spareHolder: Holder = new Holder(null);
let link: Link = new Link(null);
let maybe: Witness | null = null;
let slot: Slot = { w: null };
let spareSlot: Slot = { w: null };
let outer: Outer = { inner: { w: null } };
let either: Witness | string = "none";
let pair: [Witness | null, int32] = [null, 0];

function makeSlot(tag: int32): Slot {
	return { w: new Witness(tag) };
}

function makeOuter(tag: int32): Outer {
	return { inner: makeSlot(tag) };
}

function makeEither(tag: int32): Witness | string {
	return new Witness(tag);
}

function makePair(tag: int32): [Witness | null, int32] {
	return [new Witness(tag), tag];
}

function readWatched(what: string): int32 {
	if (what == "holder") return tagOf(holder.w);
	if (what == "link") return tagOf(link.w);
	if (what == "maybe") return tagOf(maybe);
	if (what == "slot") return tagOf(slot.w);
	if (what == "outer") return tagOf(outer.inner.w);
	if (what == "either") return eitherTag(either);
	return tagOf(pair[0]);
}

function classRefSink(): void {
	holder = new Holder(new Witness(1));
	watch("holder");
	holder = new Holder(new Witness(2));
	check("class ref sink");
}

function classRefCopy(): void {
	holder = new Holder(new Witness(1));
	spareHolder = new Holder(new Witness(2));
	watch("holder");
	holder = spareHolder;
	check("class ref copy");
}

function cyclicRefSink(): void {
	link = new Link(new Witness(1));
	watch("link");
	link = new Link(new Witness(2));
	check("cyclic class ref sink");
}

function nullableRefSink(): void {
	maybe = new Witness(1);
	watch("maybe");
	maybe = new Witness(2);
	check("nullable ref sink");
}

function structFieldSink(): void {
	slot = makeSlot(1);
	watch("slot");
	slot = makeSlot(2);
	check("struct ref field sink");
}

function structFieldCopy(): void {
	slot = makeSlot(1);
	spareSlot = makeSlot(2);
	watch("slot");
	slot = spareSlot;
	check("struct ref field copy");
}

function nestedStructSink(): void {
	outer = makeOuter(1);
	watch("outer");
	outer = makeOuter(2);
	check("nested struct sink");
}

function unionSink(): void {
	either = makeEither(1);
	watch("either");
	either = makeEither(2);
	check("union sink");
}

function tupleSink(): void {
	pair = makePair(1);
	watch("pair");
	pair = makePair(2);
	check("tuple sink");
}

classRefSink();
classRefCopy();
cyclicRefSink();
nullableRefSink();
structFieldSink();
structFieldCopy();
nestedStructSink();
unionSink();
tupleSink();
if (failures != "") throw new Error(failures);
console.log("values stored before release");
