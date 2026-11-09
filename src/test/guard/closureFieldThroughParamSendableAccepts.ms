// The legal neighbours of closureFieldThroughParamRejects.ms: a field declared Sendable is called by a
// callee that received its holder, inside a task; a holder the task builds itself is handed to a callee
// that calls its field through a const alias, of the field or of an object on the path to it, or
// through what a call on the holder returns, whose closure calls the holder it was built over.
//
// INVARIANT (ULTRALOCK V0): a Sendable function type carries the proof, checked where the closure is
//   stored into the field, so the call through it crosses.
//
// RED MEANS: the effect walk refuses a call through a Sendable field.
//
// GUARD-JS

class H { f: Sendable<() => int32>; constructor(f: Sendable<() => int32>) { this.f = f; } }
function viaParam(h: Readonly<H>): int32 { return h.f(); }
class P { f: () => int32; constructor(f: () => int32) { this.f = f; } }
function viaAlias(p: Readonly<P>): int32 { const f = p.f; return f(); }
class S { inner: P | null; constructor(inner: P) { this.inner = inner; } }
class Q { f: () => int32; constructor(f: () => int32) { this.f = f; } }
function wrapQ(p: Readonly<P>): Q { return new Q((): int32 => p.f() + 1); }
function viaCallResult(p: Readonly<P>): int32 { const q = wrapQ(p); return q.f(); }
function viaMidAlias(s: Readonly<S>): int32 { const inner = s.inner; if (inner !== null) { return inner.f(); } return 0; }

async function main(): Promise<void> {
	const h = new H((): int32 => 7);
	const a = await spawn((): int32 => viaParam(h));
	const b = await spawn((): int32 => viaAlias(new P((): int32 => 5)));
	const c = await spawn((): int32 => viaMidAlias(new S(new P((): int32 => 3))));
	const d = await spawn((): int32 => viaCallResult(new P((): int32 => 4)));
	console.log(`a=${a} b=${b} c=${c} d=${d}`);
	if (a == 7 && b == 5 && c == 3 && d == 5) console.log("GUARD-OK");
}

await main();
