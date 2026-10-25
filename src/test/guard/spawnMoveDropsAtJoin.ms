// nim-guard: spawn { move } — a moved capture is dropped by the time `await` returns.
//
// INVARIANT (ULTRALOCK T4, T5): when `await` returns, every moved capture the
//   task did not return has been dropped; a task skipped at a scope's exit
//   join drops its moved capture exactly once before the scope has left.
//   The task's captures are destroyed with the task, not with the spawning
//   scope.
//
// WHAT IT CATCHES: the task closure, and the moved capture it owns, living
//   until the spawning scope ends. Red on 5b339faeb: `moved` lags one per await.
//
// RED MEANS: a moved capture is still alive right after its `await`, an
//   unmoved capture the parent reads after the `await` is dropped early, or
//   a skipped task's capture is dropped twice or not at all, or a spawn of a
//   named function (no env) stops building.
//
// GUARD-BALANCE MovedBox
// GUARD-BALANCE KeptBox
//
// The counters are plain module lets, not a Locked cell: every drop here runs
// on the parent thread at the join, and a Locked update inside a hook run
// during a throw's unwinding is skipped (a separate bug).

let moved: int32 = 0;
let kept: int32 = 0;
class MovedBox { v: int32; constructor(v: int32) { this.v = v; } }
class KeptBox { v: int32; constructor(v: int32) { this.v = v; } }
function onDestroy(this x: MovedBox): void { moved += 1; }
function onDestroy(this x: KeptBox): void { kept += 1; }

let bad: int32 = 0;

function handleAwait(i: int32): void {
	const m = new MovedBox(i);
	const k = new KeptBox(i);
	const before = moved;
	const f = spawn(() => { return m.v + k.v; }, { move: [m] });
	const r = await f;
	if (moved != before + 1 || r != 2 * i) bad += 1;
	if (k.v != i) bad += 1;
}

function fusedAwait(i: int32): void {
	const m = new MovedBox(i);
	const before = moved;
	const r = await spawn(() => { return m.v + 1; }, { move: [m] });
	if (moved != before + 1 || r != i + 1) bad += 1;
}

function arrayMoved(i: int32): void {
	const xs: MovedBox[] = [new MovedBox(i), new MovedBox(i + 1)];
	const before = moved;
	const f = spawn(() => { return xs.length; }, { move: [xs] });
	const n = await f;
	if (moved != before + 2 || n != 2) bad += 1;
}

function notMoved(i: int32): void {
	const m = new MovedBox(i);
	const before = moved;
	const f = spawn(() => { return m.v; });
	const r = await f;
	if (moved != before || r != m.v) bad += 1;
}

function fortyOne(): int32 { return 41; }

function makeThunk(k: int32): Sendable<() => int32> { return (): int32 => { return k + 1; }; }

function namedFunction(): void {
	const a = await spawn(fortyOne);
	const f = spawn(fortyOne);
	const b = await f;
	const c = await spawn(makeThunk(1));
	const g = spawn(makeThunk(2));
	const d = await g;
	if (a != 41 || b != 41 || c != 2 || d != 3) bad += 1;
}

function skippedAtExit(n: int32): void {
	const m0 = new MovedBox(0); const f0 = spawn(() => { return m0.v; }, { move: [m0] });
	const m1 = new MovedBox(1); const f1 = spawn(() => { return m1.v; }, { move: [m1] });
	if (n > 0) { throw "leave"; }
	console.log(`${await f0 + await f1}`);
}

for (let i = 0; i < 50; i += 1) {
	handleAwait(i);
	fusedAwait(i);
	arrayMoved(i);
	notMoved(i);
	namedFunction();
}
const movedBefore = moved;
try { skippedAtExit(1); } catch (e) { }
if (moved != movedBefore + 2) bad += 1;
if (kept != 50) bad += 1;
if (bad == 0) console.log("GUARD-OK");
else { console.log(`bad=${bad} moved=${moved} kept=${kept}`); process.exit(1); }
