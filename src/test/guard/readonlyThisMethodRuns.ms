// nim-guard: a class method declares a read-only receiver TypeScript-style —
//   `peek(this: Readonly<C>)` — and is callable through a Readonly<C> view,
//   from a spawn thunk's borrow, and on a plain instance.
//
// INVARIANT (PARALOCK Amendment M): the receiver type written on `this` IS the
//   method's first parameter type; `Readonly<C>` there makes the method the
//   read-only entry point the E24 receiver rule looks for, so a view may call
//   it while a method with a plain receiver stays refused through the view.
//
// WHAT IT CATCHES: the parser dropping the `this: T` form (the pre-fix binary
//   reported `Expected '{'`), the collector prepending a second synthetic
//   `this`, or the receiver check refusing the view call.
//
// RED MEANS: a `this: Readonly<C>` method fails to parse, fails to resolve
//   through a view, or returns the wrong value.

class Tally {
	n: int32 = 3;
	peek(this: Readonly<Tally>): int32 { return this.n; }
	sum(this: Readonly<Tally>, extra: int32): int32 { return this.n + extra; }
	bump(): void { this.n += 1; }
}

class Box<T> {
	item: T;
	constructor(item: T) { this.item = item; }
	get(this: Readonly<Box<T>>): T { return this.item; }
}

function throughView(): int32 {
	const t = new Tally();
	t.bump();
	const v: Readonly<Tally> = t;
	return v.peek() + v.sum(10);
}

function fromThunk(): int32 {
	const t = new Tally();
	const f = spawn(() => t.peek() + t.sum(1));
	return await f;
}

function direct(): int32 {
	const t = new Tally();
	return t.peek();
}

function genericView(): int32 {
	const b = new Box<int32>(21);
	const v: Readonly<Box<int32>> = b;
	return v.get() * 2;
}

function main(): int32 {
	const a = throughView();
	const b = fromThunk();
	const c = direct();
	const d = genericView();
	if (a != 18) { throw "GUARD RED: throughView"; }
	if (b != 7) { throw "GUARD RED: fromThunk"; }
	if (c != 3) { throw "GUARD RED: direct"; }
	if (d != 42) { throw "GUARD RED: genericView"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(main());
