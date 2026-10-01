// bug587 — a lock callback licensed writes to anything the spawn thunk captured
//
// Symptom:    inside a spawn thunk, a lockedUpdate / lockedRead callback could write
//             any captured binding. Two thunks, each with a gate of its own, raised
//             one captured counter 100000 times each and C printed 165668 (TSan: data
//             race); a user function merely named `lockedUpdate` got the same licence.
// Root cause: callResolve cleared the spawn read-only boundary for the second
//             argument of any callee whose identifier was lockedUpdate or lockedRead
//             (Amendment L's E147), so the lock opened state it does not guard.
// Fix:        the exemption is gone (PARALOCK Amendment N, after the reference's
//             guardDotAccess): captures stay Readonly<T> inside the callback, and the
//             payload parameter is the only location the lock opens.

import { compileToCWithStd } from "../helpers";

function cError(body: string): string {
	const c = compileToCWithStd(`interface Counter { n: int32; }
function run(): int32 { ${body} }
console.log(\`\${run()}\`);`);
	return c.ok ? "compiled" : c.error;
}

test "bug587: a gate made inside the thunk does not open a capture" {
	assert cError(`const c: Counter = { n: 0 };
const f = spawn(() => { const gate = new Locked<int32>(0); lockedUpdate(gate, (v: int32): int32 => { c.n = c.n + 1; return v; }); return 0; });
await f; return c.n;`).includes("cannot write through Readonly<Counter>");
}

test "bug587: a shared gate does not open a capture" {
	assert cError(`const gate = new Locked<int32>(0);
const c: Counter = { n: 0 };
const f = spawn(() => { lockedUpdate(gate, (v: int32): int32 => { c.n = c.n + 1; return v + 1; }); return 0; });
await f; return c.n;`).includes("cannot write through Readonly<Counter>");
}

test "bug587: a read section does not open a capture" {
	assert cError(`const gate = new Locked<int32>(0);
const c: Counter = { n: 0 };
const f = spawn(() => lockedRead(gate, (v: int32): int32 => { c.n = v + 1; return c.n; }));
return await f;`).includes("cannot write through Readonly<Counter>");
}

test "bug587: a mutating builtin on a capture stays refused under a gate" {
	assert cError(`const gate = new Locked<int32>(0);
const items: int32[] = [];
const f = spawn(() => { lockedUpdate(gate, (v: int32): int32 => { items.push(9); return v; }); return 0; });
await f; return items.length;`).includes("'push' mutates its receiver");
}

test "bug587: a user function named lockedUpdate opens nothing" {
	const c = compileToCWithStd(`interface Counter { n: int32; }
function lockedUpdate(g: int32, fn: (v: int32) => int32): void { fn(g); }
function run(): int32 {
	const c: Counter = { n: 0 };
	const f = spawn(() => { lockedUpdate(0, (v: int32): int32 => { c.n = c.n + 1; return v; }); return 0; });
	await f;
	return c.n;
}
console.log(\`\${run()}\`);`);
	assert !c.ok && c.error.includes("cannot write through Readonly<Counter>");
}
