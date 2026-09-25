// nim-guard: a named catch variable is released on every exit of its handler
//
// INVARIANT (injectdestructors.nim:743 nkTryStmt: each except branch is its own
//   scope through processScope, so a jump out of the handler runs its finalizers;
//   NIM-REF AN-7 consume-once): the caught Error is destroyed once whether the
//   handler falls through, breaks, continues, returns or throws a new error.
//
// WHAT IT CATCHES: the catch variable's destroy appended to the end of the handler
//   body instead of going through assembleScope, so a break, continue, return or
//   throw inside the handler skips it and the Error leaks.
//
// RED MEANS: a handler exit stopped releasing the catch variable. Run /trace-nim on
//   processTryCatch in inject.ms.
// GUARD-BALANCE Error
// GUARD-JS

function boom(n: int32): void { if (n >= 0) throw new Error("boom"); }

function fallsOff(n: int32): int32 {
	let r = 0;
	try { boom(n); } catch (e) { r = e.message.length; }
	return r;
}

function breaksAndContinues(): int32 {
	let r = 0;
	for (let i: int32 = 0; i < 6; i += 1) {
		try { boom(i); } catch (e) { r += 1; if (i == 4) break; continue; }
		r += 100;
	}
	return r;
}

function returns(n: int32): int32 {
	try { boom(n); } catch (e) { if (n > 1) return 1; return 2; }
	return 3;
}

function wraps(n: int32): void {
	try { boom(n); } catch (e) { throw new Error("wrapped " + e.message); }
}

function run(): string {
	let t = 0;
	for (let i: int32 = 0; i < 3; i += 1) {
		t += fallsOff(i);
		t += returns(i);
		try { wraps(i); } catch (w) { t += w.message.length; }
	}
	return t.toString() + " " + breaksAndContinues().toString();
}

if (run() == "53 5") {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
