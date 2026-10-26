// nim-guard: a `move` into a spawn thunk or an actor call ends the parent's use of the binding
//
// INVARIANT (ULTRALOCK E24, E148): after `move x` crosses into a spawn thunk or an actor call,
//   a later use of x is an error on every path that reaches it: straight-line, after an `if`
//   that moved it on one branch, and on the next iteration of a loop that moves a binding
//   declared outside it. An actor call's `move` meets the same sole-owner rule as a spawn's.
//
// WHAT IT CATCHES: the tracker degrading to the state where only a straight-line spawn move was
//   tracked: an actor-call move left the binding live (C then read through a null pointer), and a
//   move under `if` or a loop was dropped at the join.
//
// RED MEANS: one of the refusals stopped firing; trace the join in checkPass.ms and
//   mergeConsumeBranches before touching a tag.
//
// GUARD-JS
// GUARD-CHECK-FAIL 'afterCall' was moved into a spawn thunk or an actor call
// GUARD-CHECK-FAIL 'afterSend' was moved into a spawn thunk or an actor call
// GUARD-CHECK-FAIL 'afterWrite' was moved into a spawn thunk or an actor call
// GUARD-CHECK-FAIL 'afterIf' was moved into a spawn thunk or an actor call
// GUARD-CHECK-FAIL 'spawnIf' was moved into a spawn thunk or an actor call
// GUARD-CHECK-FAIL 'inLoop' is moved inside a loop
// GUARD-CHECK-FAIL 'spawnFor' is moved inside a loop
// GUARD-CHECK-FAIL 'spawnWhile' is moved inside a loop
// GUARD-CHECK-FAIL cannot move 'topAlias': it is not the sole owner
// GUARD-CHECK-FAIL cannot move 'viaAlias': it is not the sole owner

interface Counter { n: int32; }
class T { n: int32 = 0; }
actor Io {
	bump(t: T): int32 { t.n = t.n + 1; return t.n; }
	add(t: T): void { t.n = t.n + 1; }
}

async function actorCall(io: Io): Promise<int32> {
	const afterCall = new T();
	await io.bump(move afterCall);
	return afterCall.n;
}

async function actorSend(io: Io): Promise<int32> {
	const afterSend = new T();
	io.add(move afterSend);
	return afterSend.n;
}

async function actorWrite(io: Io): Promise<void> {
	const afterWrite = new T();
	await io.bump(move afterWrite);
	afterWrite.n = 100;
}

async function actorIf(io: Io, flag: boolean): Promise<int32> {
	const afterIf = new T();
	if (flag) { await io.bump(move afterIf); }
	return afterIf.n;
}

async function actorLoop(io: Io): Promise<void> {
	const inLoop = new T();
	for (let i = 0; i < 2; i = i + 1) { await io.bump(move inLoop); }
}

async function actorAlias(io: Io): Promise<void> {
	const held = new T();
	let viaAlias = held;
	await io.bump(move viaAlias);
	held.n = 100;
}

async function spawnIf(flag: boolean): Promise<int32> {
	const spawnIf: Counter = { n: 5 };
	if (flag) {
		const h = spawn(() => { spawnIf.n = spawnIf.n + 1; return spawnIf.n; }, { move: [spawnIf] });
		await h;
	}
	return spawnIf.n;
}

async function spawnForLoop(): Promise<void> {
	const spawnFor: Counter = { n: 7 };
	for (let i = 0; i < 2; i = i + 1) {
		const h = spawn(() => { spawnFor.n = spawnFor.n + 1; return spawnFor.n; }, { move: [spawnFor] });
		await h;
	}
}

async function spawnWhileLoop(): Promise<void> {
	const spawnWhile: Counter = { n: 7 };
	let i = 0;
	while (i < 2) {
		i = i + 1;
		const h = spawn(() => { spawnWhile.n = spawnWhile.n + 1; return spawnWhile.n; }, { move: [spawnWhile] });
		await h;
	}
}

const io = new Io();
console.log(await actorCall(io), await actorSend(io), await actorIf(io, true));
await actorWrite(io);
await actorLoop(io);
await actorAlias(io);
console.log(await spawnIf(true));
await spawnForLoop();
await spawnWhileLoop();
for (let r = 0; r < 2; r = r + 1) {
	const topHeld = new T();
	let topAlias = topHeld;
	await io.bump(move topAlias);
	topHeld.n = 100;
}
