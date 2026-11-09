// A task that hands a captured object to a routine calling the object's function field is refused
//
// INVARIANT (ULTRALOCK V0): a callee the checker cannot see counts as reaching module state. A call
//   through a field of a routine's own parameter is judged where the caller builds the value, so a
//   value the task captured, not built by it, is refused where it is handed to such a callee.
//
// WHAT IT CATCHES: a closure built outside the task, stored in a field, called by a callee that
//   received its holder as a parameter, directly and through a const alias of the field, from a
//   task and from a Sendable factory that captured the holder.
//
// RED MEANS: the effect walk lets a call through a parameter's field cross, so the closure writes
//   module state from the task's thread while main reads it.
//
// GUARD-JS
// GUARD-CHECK-FAIL a captured value holding a function value it may call

let counter: int32[] = [];
class H { f: () => void; constructor(f: () => void) { this.f = f; } }
function viaParam(h: Readonly<H>): void { h.f(); }
function viaAlias(h: Readonly<H>): void { const f = h.f; f(); }

function factory(): Sendable<() => int32> {
	const h = new H((): void => { counter.push(2); });
	return (): int32 => { viaParam(h); return 1; }; // GUARD-REFUSED
}

async function main(): Promise<void> {
	const h = new H((): void => { counter.push(1); });
	const a = await spawn((): int32 => { viaParam(h); return 1; }); // GUARD-REFUSED
	const b = await spawn((): int32 => { viaAlias(h); return 1; }); // GUARD-REFUSED
	console.log(a + b + factory()() + counter.length);
}

await main();
