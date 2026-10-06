// nim-guard: a raising call stores into an observable location only after its raise check
//
// INVARIANT (ccgcalls.nim:155-160 fixupCall with isHarmlessStore :84-93): when a
//   handler or a caller can read the target on the raise path, the call's value
//   goes to a temporary, the raise exits, and only a returned value is stored.
//   MS extends the order to struct results (NIM-REF CG-47, safety).
//
// WHAT IT CATCHES: the assignment storing the callee's zeroed result before the
//   raise check (the old value is lost), and the temporary carrying a managed
//   field leaking or being destroyed twice on the caught path. Axes: a plain
//   struct local, a struct with a class field in a local and in a global, a
//   scalar global set from a function the raise leaves.
//
// RED MEANS: the C statement emission stored before its raise check, or the
//   analyzer lost the temporary of a managed result. Run /trace-nim on fixupCall.
// GUARD-BALANCE RkBox
// GUARD-JS

class RkBox { v: int32; constructor(v: int32) { this.v = v; } }
struct Plain { n: int64; pad1: int64; pad2: int64; pad3: int64; }
struct Held { n: int64; box: RkBox; }

let held: Held = { n: 7, box: new RkBox(7) };
let count: int32 = 7;

function plain(n: int64): Plain {
	if (n < 0) { throw new Error("neg"); }
	return { n: n, pad1: 0, pad2: 0, pad3: 0 };
}
function hold(n: int64): Held {
	const box = new RkBox(n as int32);
	if (n < 0) { throw new Error("neg"); }
	return { n: n, box: box };
}
function bump(n: int32): int32 {
	if (n < 0) { throw new Error("neg"); }
	return n;
}
function setCount(): void { count = bump(-1); }

function run(): boolean {
	let p = plain(1);
	let h = hold(2);
	for (let i: int32 = 0; i < 3; i += 1) {
		try { p = plain(-1); } catch (e) { }
		try { h = hold(-1); } catch (e) { }
		try { held = hold(-1); } catch (e) { }
		try { setCount(); } catch (e) { }
	}
	try { h = hold(3); } catch (e) { }
	return p.n == 1 && h.n == 3 && h.box.v == 3 && held.n == 7 && held.box.v == 7 && count == 7;
}

if (run()) {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
