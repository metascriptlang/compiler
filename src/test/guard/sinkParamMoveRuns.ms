// nim-guard: `move` of a `sink` parameter — the callee owns it and may move it on.
//
// INVARIANT (PARALOCK E148): a `sink` parameter is not "a parameter the caller still owns": the
//   callee may move it into an actor call, a spawn thunk or a plain function, and the moved-from
//   parameter is not destroyed again at the callee's scope end. A plain parameter stays refused
//   (guard paralockSpawnMoveRejects, case 9).
//
// WHAT IT CATCHES: the parameter symbol losing its sink mode when its type is unwrapped, so every
//   `move` of a sink parameter is refused as a plain one; and a moved sink parameter freed twice.
//
// RED MEANS: E148 refuses one of the moves below, a moved value reads null, or SAN reports a
//   double free.

class Conn { n: int32 = 0; }
class Slot { held: Conn | null = null; }

actor Hub {
	total: int32 = 0;
	take(c: Conn): int32 { this.total += c.n; return this.total; }
}

function plain(c: Conn): int32 { return c.n; }
function keep(s: Slot, sink c: Conn): void { s.held = c; }

function intoActor(h: Hub, sink conn: Conn): Promise<int32> { return h.take(move conn); }
function intoPlain(sink conn: Conn): int32 { return plain(move conn); }
function intoSink(s: Slot, sink conn: Conn): void { keep(s, move conn); }
async function intoSpawn(sink conn: Conn): Promise<int32> {
	const f = spawn(() => { conn.n = conn.n + 1; return conn.n; }, { move: [conn] });
	return await f;
}

function fresh(n: int32): Conn {
	const c = new Conn();
	c.n = n;
	return c;
}

async function main(): Promise<int32> {
	const h = new Hub();
	const a = await intoActor(h, fresh(2));
	const b = intoPlain(fresh(3));
	const s = new Slot();
	intoSink(s, fresh(4));
	const d = await intoSpawn(fresh(5));
	if (a != 2) { throw "GUARD RED: intoActor"; }
	if (b != 3) { throw "GUARD RED: intoPlain"; }
	if (s.held == null || s.held!.n != 4) { throw "GUARD RED: intoSink"; }
	if (d != 6) { throw "GUARD RED: intoSpawn"; }
	console.log("GUARD-OK");
	return 0;
}

process.exit(await main());
