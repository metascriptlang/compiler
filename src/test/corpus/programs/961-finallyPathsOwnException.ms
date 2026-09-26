// @xfail(raiser): Raiser cannot run `super(m)` in a constructor of a class extending Error (Tagged_new: "cannot evaluate 'super' at comptime"), also on the baseline
// @stdout: t|f|o:through|caught|f2|bare|f3|f4|o:re|f5|o:fromcatch orig|o:fin only|o:winner|c|f6|1|inner|after inner|o:outer flight
// note: every path through a finally keeps one owner for the exception in flight (the SAN ledger balances Error and Tagged): no raise, a raise that passes through, caught by a named or bare catch, rethrown, replaced from the catch, raised in the finally with none in flight, displaced by a raise in the finally, a return from the catch, and a raise caught inside the finally (the baseline panicked on a null Error).

class Tagged extends Error { tag: string; constructor(m: string, t: string) { super(m); this.tag = t; } }

function boom(m: string): void { throw new Error(m); }

function noRaise(out: string[]): void {
	try { out.push("t"); } finally { out.push("f"); }
}

function raiseThrough(): void {
	try { boom("through"); } finally { }
}

function catchThenFinally(out: string[]): void {
	try { boom("caught"); } catch (e) { out.push(e.message); } finally { out.push("f2"); }
}

function bareCatchThenFinally(out: string[]): void {
	try { boom("bare"); } catch { out.push("bare"); } finally { out.push("f3"); }
}

function rethrowThroughFinally(out: string[]): void {
	try { boom("re"); } catch (e) { throw e; } finally { out.push("f4"); }
}

function newRaiseInCatch(out: string[]): void {
	try { boom("orig"); } catch (e) { throw new Tagged("fromcatch " + e.message, "k"); } finally { out.push("f5"); }
}

function throwInFinallyNoFlight(): void {
	try { } finally { throw new Tagged("fin only", "q"); }
}

function throwInFinallyDisplaces(): void {
	try { throw new Tagged("displaced", "d"); } finally { throw new Error("winner"); }
}

function returnInFinallyAfterCatch(out: string[]): int32 {
	try { boom("c"); } catch (e) { out.push(e.message); return 1; } finally { out.push("f6"); }
	return 0;
}

function rethrowInFinallyNested(out: string[]): void {
	try {
		boom("outer flight");
	} finally {
		try { boom("inner"); } catch (e) { out.push(e.message); }
		out.push("after inner");
	}
}

function run(): string {
	let line = "";
	for (let i: int32 = 0; i < 3; i += 1) {
		const out: string[] = [];
		noRaise(out);
		try { raiseThrough(); } catch (e) { out.push("o:" + e.message); }
		catchThenFinally(out);
		bareCatchThenFinally(out);
		try { rethrowThroughFinally(out); } catch (e) { out.push("o:" + e.message); }
		try { newRaiseInCatch(out); } catch (e) { out.push("o:" + e.message); }
		try { throwInFinallyNoFlight(); } catch (e) { out.push("o:" + e.message); }
		try { throwInFinallyDisplaces(); } catch (e) { out.push("o:" + e.message); }
		out.push(returnInFinallyAfterCatch(out).toString());
		try { rethrowInFinallyNested(out); } catch (e) { out.push("o:" + e.message); }
		line = out.join("|");
	}
	return line;
}
console.log(run());
