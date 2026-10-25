// A closure bound to a name and then spawned is the closure the inline thunk would be, so it gets the
// inline thunk's checks: the parent may not change what the closure captures while the task reads it,
// the closure may not reach a mutable capture directly or through another closure it calls, and the
// refusals name the capture or the call. The legal neighbour (a read-only capture, no parent write
// in the span) is pinned by spawnNamedClosureAccepts.ms, which must build and run, with the const aliases of such a closure.
//
// GUARD-CHECK-FAIL 'constRing' is lent to the spawn
// GUARD-CHECK-FAIL 'calledRing' is lent to the spawn
// GUARD-CHECK-FAIL 'sendRing' is lent to the spawn
// GUARD-CHECK-FAIL mutable variable 'directN' cannot be captured by spawn
// GUARD-CHECK-FAIL mutable variable 'viaN' cannot be captured by spawn
// GUARD-CHECK-FAIL 'makeCutter(...)' is a function value
// GUARD-CHECK-FAIL the closure bound to 'movedCut' captures 'movedRing'
// GUARD-CHECK-FAIL 'nestedRing' is lent to the spawn
// GUARD-CHECK-FAIL mutable variable 'nestedN' cannot be captured by spawn
// GUARD-CHECK-FAIL 'aliasRing' is lent to the spawn
// GUARD-CHECK-FAIL 'hopRing' is lent to the spawn
// GUARD-CHECK-FAIL 'inlineNestedRing' is lent to the spawn
// GUARD-CHECK-FAIL it uses module-level 'declHits'
class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder { child: Child; constructor(c: Child) { this.child = c; } }

function makeCutter(h: Holder): () => int32 { return (): int32 => h.child.v; }

function constBound(): int32 {
	const constRing = new Holder(new Child(1));
	const cut = (): int32 => constRing.child.v;
	const f = spawn(cut); // GUARD-REFUSED
	constRing.child = new Child(2);
	return await f;
}

function calledFromThunk(): int32 {
	const calledRing = new Holder(new Child(1));
	const cut = (): int32 => calledRing.child.v;
	const f = spawn((): int32 => cut()); // GUARD-REFUSED
	calledRing.child = new Child(2);
	return await f;
}

function sendableBound(): int32 {
	const sendRing = new Holder(new Child(1));
	const cut: Sendable<() => int32> = (): int32 => sendRing.child.v;
	const f = spawn(cut); // GUARD-REFUSED
	sendRing.child = new Child(2);
	return await f;
}

function letBound(): int32 {
	let directN: int32 = 0;
	const bump = (): int32 => { directN += 1; return directN; }; // GUARD-REFUSED
	return await spawn(bump);
}

function letThroughCallee(): int32 {
	let viaN: int32 = 0;
	const bump = (): int32 => { viaN += 1; return viaN; }; // GUARD-REFUSED
	return await spawn((): int32 => bump());
}

function factory(): int32 {
	const facRing = new Holder(new Child(1));
	return await spawn(makeCutter(facRing)); // GUARD-REFUSED
}

function movedCapturing(): int32 {
	const movedRing = new Holder(new Child(1));
	const movedCut = (): int32 => movedRing.child.v;
	return await spawn((): int32 => movedCut(), { move: [movedCut] }); // GUARD-REFUSED
}

async function nestedFnLend(): Promise<int32> {
	const nestedRing = new Holder(new Child(1));
	const cut = (): int32 => nestedRing.child.v;
	async function run(): Promise<int32> {
		const f = spawn(cut); // GUARD-REFUSED
		nestedRing.child = new Child(2);
		return await f;
	}
	return await run();
}

async function nestedFnLet(): Promise<int32> {
	let nestedN: int32 = 0;
	const bump = (): int32 => { nestedN += 1; return nestedN; }; // GUARD-REFUSED
	async function run(): Promise<int32> { return await spawn(bump); }
	return await run();
}

async function aliasLend(): Promise<int32> {
	const aliasRing = new Holder(new Child(1));
	const cut = (): int32 => aliasRing.child.v;
	const g = cut;
	const f = spawn(g); // GUARD-REFUSED
	aliasRing.child = new Child(2);
	return await f;
}

async function twoHopLend(): Promise<int32> {
	const hopRing = new Holder(new Child(1));
	const cut = (): int32 => hopRing.child.v;
	const g = cut;
	const h = g;
	const f = spawn(h); // GUARD-REFUSED
	hopRing.child = new Child(2);
	return await f;
}

async function nestedFnInline(): Promise<int32> {
	const inlineNestedRing = new Holder(new Child(1));
	async function run(): Promise<int32> {
		const f = spawn((): int32 => inlineNestedRing.child.v); // GUARD-REFUSED
		inlineNestedRing.child = new Child(2);
		return await f;
	}
	return await run();
}

let declHits = 0;
function bumpHits(): int32 { declHits = declHits + 1; return declHits; }

async function declAliasWrite(): Promise<int32> {
	const g = bumpHits;
	return await spawn(g); // GUARD-REFUSED
}

async function main(): Promise<void> {
	console.log(`r=${constBound() + calledFromThunk() + sendableBound() + letBound() + letThroughCallee() + factory() + movedCapturing() + await nestedFnLend() + await nestedFnLet() + await aliasLend() + await twoHopLend() + await nestedFnInline() + await declAliasWrite()}`);
}
main();
