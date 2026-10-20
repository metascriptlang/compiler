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

test "a generic extension then reaches no type, and a then extension counts only on the type it names" {
	const result = checkOnly(`
class Plain { n: int32 = 4; }
class Handle { id: int32 = 7; }
export function then(this h: Handle, onFulfilled: (v: int32) => void): void { onFulfilled(h.id); }
export function then<T>(this x: T, onFulfilled: (v: string) => void): void { onFulfilled("captured"); }
async function main(): Promise<void> {
	const a: int32 = await new Handle();
	const b: Plain = await Promise.resolve(new Plain());
	const c: string = await Promise.resolve(new Plain());
}
`);
	const text = result.errors.join("\n");
	assert result.errors.length == 1, "only the Plain read as a string: " + text;
	assert text.contains("Plain"), text;
}

test "an async return and Promise.resolve adopt a thenable, typed by what its then delivers" {
	const result = checkOnly(`
class Now {
	then(onFulfilled: (v: int32) => void): void { onFulfilled(5); }
}
async function declared(): Promise<int32> { return new Now(); }
async function inferred() { return new Now(); }
const arrow = async () => new Now();
async function main(): Promise<void> {
	const a: int32 = await declared();
	const b: int32 = await inferred();
	const c: int32 = await arrow();
	const d: int32 = await Promise.resolve(new Now());
	const e: int32[] = await Promise.all([new Now(), Promise.resolve(6)]);
	const wrong: string = await inferred();
}
`);
	const text = result.errors.join("\n");
	assert result.errors.length == 1, "only the int32 read as a string: " + text;
	assert text.contains("int32"), text;
}

test "a promise of a thenable is refused where it is written or made" {
	const text = checkOnly(`
class Thing {
	then(onFulfilled: (v: int32) => void): void { onFulfilled(1); }
}
async function written(): Promise<Thing> { return new Thing(); }
async function main(): Promise<void> {
	const made = new Promise<Thing>((resolve, reject) => { resolve(new Thing()); });
	Promise.resolve(1).then((v: int32) => new Thing());
}
`).errors.join("\n");
	assert text.contains("'Promise<Thing>' is a promise of a thenable, which is refused: a promise adopts what a thenable delivers, so write 'Promise<int32>'"), text;
	assert text.contains("this call makes 'Promise<Thing>', a promise of a thenable, which is refused"), text;
	assert text.contains("a '.then' callback returns 'Thing', a thenable the promise would adopt"), text;
}

test "a class is not a promise and a promise is not a class" {
	const result = checkOnly(`
class Plain { x: int32 = 1; }
class Thing {
	then(onFulfilled: (v: int32) => void): void { onFulfilled(1); }
}
class Empty {}
async function main(): Promise<void> {
	const a: Promise<int32> = new Plain();
	const b: Promise<int32> = new Thing();
	const c: Promise<int32> = new Empty();
	const d: Empty = Promise.resolve(1);
}
`);
	const text = result.errors.join("\n");
	assert result.errors.length == 4, text;
	assert text.contains("Type 'Plain' is not assignable to type 'Promise<int32>'"), text;
	assert text.contains("Type 'Thing' is not assignable to type 'Promise<int32>'"), text;
	assert text.contains("Type 'Empty' is not assignable to type 'Promise<int32>'"), text;
	assert text.contains("Type 'Promise<int32>' is not assignable to type 'Empty'"), text;
}

test "a thenable returned inside a try with catch or finally is refused, return await is kept" {
	const result = checkOnly(`
class Thing {
	then(onFulfilled: (v: int32) => void, onRejected: (e: Error) => void): void { onRejected(new Error("thing failed")); }
}
async function caught(): Promise<int32> { try { return new Thing(); } catch (e) { return 2; } }
async function finalized(): Promise<int32> { try { return new Thing(); } finally { console.log("done"); } }
async function inCatch(): Promise<int32> { try { return 1; } catch (e) { return new Thing(); } finally { console.log("done"); } }
async function awaited(): Promise<int32> { try { return await new Thing(); } catch (e) { return 2; } }
async function outside(): Promise<int32> { try { console.log("x"); } catch (e) {} return new Thing(); }
async function nested(): Promise<int32> {
	try {
		const inner = async (): Promise<int32> => { return new Thing(); };
		return await inner();
	} catch (e) { return 2; }
}
`);
	const text = result.errors.join("\n");
	assert result.errors.length == 3, "caught, finalized and inCatch only: " + text;
	assert text.contains("a returned thenable is not awaited inside try — write `return await …` so catch and finally see its result"), text;
}
