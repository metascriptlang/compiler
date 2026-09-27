// nim-guard: the argument of a throw is walked as a sink, whatever its shape
//
// INVARIANT (injectdestructors.nim:787 pRaiseStmt: `p(n[0], c, s, sinkArg)`;
//   NIM-REF AN-7 "processThrow sinks"): the thrown value is moved into the raise,
//   and every fresh value nested inside it is destroyed like in any other position.
//
// WHAT IT CATCHES: processThrow walking only a bare identifier or a field read, so
//   `throw new E(mk())` never destroys the fresh argument (Box leaks), and a string
//   local handed to msThrow is also destroyed at scope exit (double free, crash).
//   Axes: a fresh ref argument of the constructor, one nested a level deeper in a
//   message expression, and a thrown string local.
//
// RED MEANS: processThrow stopped walking its argument. Run /trace-nim on
//   processThrow in inject.ms.
// GUARD-BALANCE TaBox
// GUARD-JS

class TaBox { v: int32; constructor(v: int32) { this.v = v; } }
class TaBoxErr extends Error {
	box: TaBox;
	constructor(msg: string, b: TaBox) { super(msg); this.box = b; }
}

function mk(v: int32): TaBox { return new TaBox(v); }
function describe(i: int32): string { return "bad " + i.toString(); }

function freshCtorArg(i: int32): void { throw new TaBoxErr("x", mk(i)); }
function nestedInMessage(i: int32): void { throw new Error("v" + mk(i).v.toString()); }
function stringLocal(i: int32): void {
	const m = describe(i);
	throw m;
}

class TaHolder { msg: string; constructor(m: string) { this.msg = m; } }

function stringField(h: TaHolder): void { throw h.msg; }
function stringElement(a: string[], i: int32): void { throw a[i]; }

function run(): int32 {
	let n = 0;
	const h = new TaHolder(describe(7));
	const a: string[] = [describe(8), describe(9)];
	for (let i: int32 = 0; i < 3; i += 1) {
		try { freshCtorArg(i); } catch (e) { n += 1; }
		try { nestedInMessage(i); } catch (e) { n += e.message.length; }
		try { stringLocal(i); } catch (e) { n += 1; }
		try { stringField(h); } catch (e) { n += 1; }
		try { stringElement(a, i % 2); } catch (e) { n += 1; }
	}
	return h.msg == "bad 7" && a[1] == "bad 9" ? n : -1;
}

if (run() == 18) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
