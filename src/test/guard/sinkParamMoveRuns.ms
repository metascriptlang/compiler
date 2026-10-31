// nim-guard: `move` of a `sink` parameter — the callee owns it and may move it on.
//
// INVARIANT (PARALOCK E148): a `sink` parameter may be moved into a same-thread callee, whatever
//   it holds, and a sink parameter holding only values crosses into an actor call or a spawn
//   thunk. A sink parameter holding a reference stays refused across threads, because a caller
//   that keeps using its value passes a copy that shares the graph (guard
//   paralockSpawnMoveRejects). The moved-from parameter is not destroyed again at the callee's
//   scope end, and an arrow or function expression takes the `sink` prefix like a named function.
//
// WHAT IT CATCHES: an arrow or function expression refusing or dropping the `sink` prefix, a
//   sink parameter losing its mode when its type is unwrapped, and a moved sink parameter freed
//   twice.
//
// RED MEANS: the build fails on one of the moves below, a moved value reads null, or SAN reports
//   a double free.

class Conn { n: int32 = 0; }
class Slot { held: Conn | null = null; }
struct Frame { n: int32; w: float64 }

actor Hub {
	total: int32 = 0;
	takeFrame(f: Frame): int32 { this.total += f.n; return this.total; }
}

function plain(c: Conn): int32 { return c.n; }
function keep(s: Slot, sink c: Conn): void { s.held = c; }

function intoActor(h: Hub, sink f: Frame): Promise<int32> { return h.takeFrame(move f); }
function intoPlain(sink conn: Conn): int32 { return plain(move conn); }
function intoSink(s: Slot, sink conn: Conn): void { keep(s, move conn); }
async function intoSpawn(sink f: Frame): Promise<int32> {
	const r = spawn(() => { return f.n; }, { move: [f] });
	return await r;
}

const arrowActor = (h: Hub, sink f: Frame): Promise<int32> => h.takeFrame(move f);
const arrowPlain = (sink conn: Conn): int32 => plain(move conn);
const arrowSink = (s: Slot, sink conn: Conn): void => { keep(s, move conn); };
const exprPlain = function (sink conn: Conn): int32 { return plain(move conn); };

function fresh(n: int32): Conn {
	const c = new Conn();
	c.n = n;
	return c;
}

async function main(): Promise<int32> {
	const h = new Hub();
	const a = await intoActor(h, { n: 3, w: 1.5 });
	const b = intoPlain(fresh(3));
	const s = new Slot();
	intoSink(s, fresh(4));
	const d = await intoSpawn({ n: 5, w: 0.5 });
	const e = await arrowActor(h, { n: 7, w: 2.5 });
	const g = arrowPlain(fresh(8));
	const s2 = new Slot();
	arrowSink(s2, fresh(9));
	const k = exprPlain(fresh(10));
	if (a != 3) { throw "GUARD RED: intoActor"; }
	if (b != 3) { throw "GUARD RED: intoPlain"; }
	if (s.held == null || s.held!.n != 4) { throw "GUARD RED: intoSink"; }
	if (d != 5) { throw "GUARD RED: intoSpawn"; }
	if (e != 10) { throw "GUARD RED: arrowActor"; }
	if (g != 8) { throw "GUARD RED: arrowPlain"; }
	if (s2.held == null || s2.held!.n != 9) { throw "GUARD RED: arrowSink"; }
	if (k != 10) { throw "GUARD RED: exprPlain"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(await main());
