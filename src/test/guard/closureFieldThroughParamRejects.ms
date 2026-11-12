// A task that hands a captured object to a routine calling the object's function field is refused
//
// INVARIANT (ULTRALOCK V0): a callee the checker cannot see counts as reaching module state. A call
//   through a field of a routine's own parameter is judged where the caller builds the value, so a
//   value the task captured, not built by it, is refused where it is handed to such a callee.
//
// WHAT IT CATCHES: a closure built outside the task, stored in a field, called by a callee that
//   received its holder as a parameter, directly and through a const alias of the field, from a
//   task and from a Sendable factory that captured the holder; the holder handed on as an
//   extension receiver, through an alias made in the task, a cast or a choice; a captured holder
//   whose class builds the closure itself, called directly; the holder handed to a constructor
//   that calls its field or as the receiver of a method that calls it; and a nested function reading its outer routine's parameter, whose
//   verdict must not depend on which caller is walked first.
//
// RED MEANS: the effect walk lets a call through a parameter's field cross, so the closure writes
//   module state from the task's thread while main reads it.
//
// GUARD-JS
// GUARD-CHECK-FAIL a value holding a function value it did not build
// GUARD-CHECK-FAIL calls a function value

let counter: int32[] = [];
class H { f: () => void; constructor(f: () => void) { this.f = f; } }
function viaParam(h: Readonly<H>): void { h.f(); }
function viaAlias(h: Readonly<H>): void { const f = h.f; f(); }
function run(this h: Readonly<H>): void { h.f(); }
class G { f: () => void = (): void => { counter.push(9); }; }
class W { constructor(h: Readonly<H>) { h.f(); } }
class C3 { f: () => void; constructor(f: () => void) { this.f = f; } callF(this: Readonly<C3>): void { this.f(); } }

function nested(h: Readonly<H>): Promise<int32> {
	function inner(): int32 { h.f(); return 1; }
	const k = (): int32 => inner();
	k();
	return spawn((): int32 => inner()); // GUARD-REFUSED
}

function factory(): Sendable<() => int32> {
	const h = new H((): void => { counter.push(2); });
	return (): int32 => { viaParam(h); return 1; }; // GUARD-REFUSED
}

async function main(): Promise<void> {
	const h = new H((): void => { counter.push(1); });
	const a = await spawn((): int32 => { viaParam(h); return 1; }); // GUARD-REFUSED
	const b = await spawn((): int32 => { viaAlias(h); return 1; }); // GUARD-REFUSED
	const g = new G();
	const c = await spawn((): int32 => { g.f(); return 1; }); // GUARD-REFUSED
	const d = await spawn((): int32 => { h.run(); return 1; }); // GUARD-REFUSED
	const e = await spawn((): int32 => { const y = h; viaParam(y); return 1; }); // GUARD-REFUSED
	const f = await spawn((): int32 => { viaParam(h as Readonly<H>); return 1; }); // GUARD-REFUSED
	const i = await spawn((): int32 => { viaParam(a > 0 ? h : new H((): void => {})); return 1; }); // GUARD-REFUSED
	const w = await spawn((): int32 => { new W(h); return 1; }); // GUARD-REFUSED
	const c3 = new C3((): void => { counter.push(3); });
	const m = await spawn((): int32 => { c3.callF(); return 1; }); // GUARD-REFUSED
	console.log(a + b + c + d + e + f + i + w + m + await nested(h) + factory()() + counter.length);
}

await main();
