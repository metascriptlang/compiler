// @stdout: two=null,set,set three=null,set nested=null,set:7 hops=null,set method=null,set back=empty,y:2 value=set,set undef=undef,set closure=null null

// A `T | null` handed from one generic to another, or from a `Note | null` local into a
// generic's `T | null`, keeps the one carrier the instance declares: the argument converts
// to the instantiated formal, never to the generic one. A struct of two or more fields is
// passed by address, where a conversion to the generic formal reached the C compiler as a
// different type. A plain struct value meets the same formal through the nullable wrap.
struct Note {
	slug: string;
	text: string;
}

struct Wide {
	a: string;
	b: string;
	c: int32;
}

struct Inner {
	n: int32;
	tag: string;
}

struct Outer {
	name: string;
	inner: Inner;
}

function inner<T>(prev: T | null): string {
	return prev === null ? "null" : "set";
}

function outer<T>(prev: T | null): string {
	return inner<T>(prev);
}

function hop3<T>(prev: T | null): string {
	return outer<T>(prev);
}

function nestedN(prev: Outer | null): int32 {
	return prev === null ? 0 : prev.inner.n;
}

function nestedOuter<T>(prev: T | null): string {
	return inner<T>(prev);
}

class Keeper {
	label: string;

	constructor(label: string) {
		this.label = label;
	}

	look<T>(prev: T | null): string {
		return outer<T>(prev);
	}
}

function backInner<T>(prev: T | null): T | null {
	return prev;
}

function backOuter<T>(prev: T | null): T | null {
	return backInner<T>(prev);
}

function innerUndef<T>(prev: T | undefined): string {
	return prev === undefined ? "undef" : "set";
}

function outerUndef<T>(prev: T | undefined): string {
	return innerUndef<T>(prev);
}

function captured<T>(prev: T | null): string {
	const later = (): string => inner<T>(prev);
	return inner<T>(prev) + " " + later();
}

function noteOrNull(set: boolean): Note | null {
	if (set) {
		const n: Note = { slug: "s", text: "t" };
		return n;
	}
	return null;
}

export function main(): void {
	const absent: Note | null = noteOrNull(false);
	const present: Note | null = noteOrNull(true);
	const two = [outer<Note>(null), outer<Note>(present), inner<Note>(present)].join(",");
	if (absent !== null) console.log("absent should be null");

	const wideSet: Wide | null = { a: "x", b: "y", c: 3 };
	const three = [outer<Wide>(null), outer<Wide>(wideSet)].join(",");

	const deep: Outer | null = { name: "o", inner: { n: 7, tag: "i" } };
	const nested = `${nestedOuter<Outer>(null)},${nestedOuter<Outer>(deep)}:${nestedN(deep)}`;

	const hops = [hop3<Note>(absent), hop3<Note>(present)].join(",");

	const keeper = new Keeper("k");
	const method = [keeper.look<Note>(null), keeper.look<Wide>(wideSet)].join(",");

	const backNone = backOuter<Wide>(null);
	const backSome = backOuter<Wide>(wideSet);
	const back = `${backNone === null ? "empty" : "full"},${backSome === null ? "none" : backSome.b}:${backSome === null ? 0 : backSome.c - 1}`;

	const plain: Note = { slug: "a", text: "b" };
	const value = [outer<Note>(plain), inner<Note>(plain)].join(",");

	const missing: Note | undefined = undefined;
	const undef = [outerUndef<Note>(missing), outerUndef<Note>(plain)].join(",");

	const closure = captured<Note>(absent);

	console.log(`two=${two} three=${three} nested=${nested} hops=${hops} method=${method} back=${back} value=${value} undef=${undef} closure=${closure}`);
}

main();
