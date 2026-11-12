// The legal neighbours of closureFieldThroughParamRejects.ms: a field declared Sendable is called by a
// callee that received its holder, inside a task; a holder the task builds itself is handed to a callee
// that calls its field through a const alias, of the field or of an object on the path to it, or
// through what a call on the holder returns, whose closure calls the holder it was built over; a
// holder built here and handed on as a constructor's `this`, as a method's receiver, as the element a
// callee's for..of binds, as what an awaited call returns to an actor, or chosen against null; an
// actor whose field holds a function value, handed on by a Sendable function, since a pid reaches
// its fields only through messages.
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

function nine(): int32 { return 9; }
class Own { f: () => int32 = (): int32 => 11; }
function runP(this p: Readonly<P>): int32 { return p.f(); }
class Store { load: () => int32; constructor(load: () => int32) { this.load = load; } }
class Owner {
	base: int32 = 5;
	store: Store | null = null;
	got: int32 = 0;
	constructor() { this.got = firstLoad(storeOf(this)); }
}
function storeOf(o: Owner): Store { return new Store((): int32 => o.base); }
function firstLoad(s: Readonly<Store>): int32 { return s.load(); }
class C2 { f: () => int32; constructor(f: () => int32) { this.f = f; } callF(): int32 { return this.f(); } }
actor Counter { tick: () => int32 = (): int32 => 1; n: int32 = 0; bump(): void { this.n = this.n + this.tick(); } count(): int32 { return this.n; } }
function poke(c: Readonly<Counter>): void { c.bump(); }
function maybeCall(p: Readonly<P> | null): int32 { return p == null ? 0 : p.f(); }
function sumAll(ps: Readonly<P[]>): int32 { let t = 0; for (const p of ps) { t += viaAlias(p); } return t; }
async function mkP(): Promise<P> { return new P((): int32 => 6); }
actor Opener { open(): int32 { const p = await mkP(); return viaAlias(p); } }

async function builtInTask(): Promise<int32> {
	const viaLocal = await spawn((): int32 => { const p = new P((): int32 => 1); return viaAlias(p); });
	const viaNamed = await spawn((): int32 => viaAlias(new P(nine)));
	const ownField = await spawn((): int32 => { const o = new Own(); return o.f(); });
	const viaReceiver = await spawn((): int32 => new P((): int32 => 2).runP());
	const viaLocalClosure = await spawn((): int32 => { const p = new P((): int32 => 3); const k = (): int32 => viaAlias(p); return k(); });
	const viaChoice = await spawn((): int32 => viaAlias(viaLocal > 0 ? new P((): int32 => 4) : new P(nine)));
	const viaCtorThis = await spawn((): int32 => new Owner().got);
	const viaMethod = await spawn((): int32 => new C2((): int32 => 7).callF());
	const viaForOf = await spawn((): int32 => sumAll([new P((): int32 => 8)]));
	const viaMaybe = await spawn((): int32 => { const p = viaLocal > 0 ? new P((): int32 => 9) : null; return maybeCall(p); });
	return viaLocal + viaNamed + ownField + viaReceiver + viaLocalClosure + viaChoice + viaCtorThis + viaMethod + viaForOf + viaMaybe;
}

async function main(): Promise<void> {
	const h = new H((): int32 => 7);
	const a = await spawn((): int32 => viaParam(h));
	const b = await spawn((): int32 => viaAlias(new P((): int32 => 5)));
	const c = await spawn((): int32 => viaMidAlias(new S(new P((): int32 => 3))));
	const d = await spawn((): int32 => viaCallResult(new P((): int32 => 4)));
	console.log(`a=${a} b=${b} c=${c} d=${d}`);
	const built = await builtInTask();
	const counter = new Counter();
	const poker: Sendable<() => void> = (): void => { poke(counter); };
	poker();
	const ticks = await counter.count();
	const opener = new Opener();
	const opened = await opener.open();
	console.log(`built=${built} opened=${opened} ticks=${ticks}`);
	if (a == 7 && b == 5 && c == 3 && d == 5 && built == 59 && opened == 6 && ticks == 1) console.log("GUARD-OK");
}

await main();
