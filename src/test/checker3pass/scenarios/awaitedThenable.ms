import { checkOnly } from "../helpers";

const REFUSED = "Type of 'await' operand must either be a valid promise or must not contain a callable 'then' member";

test "await of a thenable gives the type its onFulfilled callback receives" {
	const result = checkOnly(`
class Now {
	then(onFulfilled: (v: int32) => void): void { onFulfilled(5); }
}
class Box<T> {
	item: T;
	constructor(item: T) { this.item = item; }
	then<R>(onFulfilled: (v: T) => R, onRejected?: (reason: Error) => R): void { onFulfilled(this.item); }
}
class Base {
	then(onFulfilled: (v: string) => void): void { onFulfilled("inherited"); }
}
class Derived extends Base {}
interface Deferred {
	then: (onFulfilled: (v: boolean) => void) => void;
}
async function main(d: Deferred): Promise<void> {
	const a: int32 = await new Now();
	const b: string = await new Box<string>("hi");
	const c: string = await new Derived();
	const e: boolean = await d;
	const wrong: string = await new Now();
}
`);
	const text = result.errors.join("\n");
	assert result.errors.length == 1, "only the int32 read as a string: " + text;
	assert text.contains("int32"), text;
}

test "a thenable whose then cannot settle an await is refused at the await" {
	const text = checkOnly(`
class Inner {
	then(onFulfilled: (v: int32) => void): void { onFulfilled(1); }
}
class Outer {
	then(onFulfilled: (v: Inner) => void): void { onFulfilled(new Inner()); }
}
class Self {
	then(onFulfilled: (v: Self) => void): void { onFulfilled(this); }
}
class Wraps {
	then(onFulfilled: (v: Promise<int32>) => void): void {}
}
class NoCallback {
	then(count: int32): void {}
}
class StringReason {
	then(onFulfilled: (v: int32) => void, onRejected: (reason: string) => void): void {}
}
class UnknownReason {
	then(onFulfilled: (v: int32) => void, onRejected: (reason: unknown) => void): void {}
}
async function main(): Promise<void> {
	const a = await new Outer();
	const b = await new Self();
	const c = await new Wraps();
	const d = await new NoCallback();
	const e = await new StringReason();
	const f = await new UnknownReason();
}
`).errors.join("\n");
	assert text.contains(REFUSED + ": 'Outer.then' delivers 'Inner', which is awaitable itself"), text;
	assert text.contains("'Self.then' delivers 'Self', which is awaitable itself"), text;
	assert text.contains("'Wraps.then' delivers 'Promise<int32>', which is awaitable itself"), text;
	assert text.contains("the first parameter of 'NoCallback.then' must be a callback"), text;
	assert text.contains("the second parameter of 'StringReason.then' must be a callback taking an Error, not 'string'"), text;
	assert text.contains("the second parameter of 'UnknownReason.then' must be a callback taking an Error, not 'unknown'"), text;
}
