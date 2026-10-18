// Parity program — an exception raised in a callee runs every finally between
// it and the catch exactly once, in the caller's frame and in frames between.
//
// @stdout: f1|caught deep|f2|f3|caught mid|ret 7|f4|caught late|end
// @exit: 0

const log: string[] = [];

function deep(): void { throw new Error("deep"); }

function sameFrame(): void {
	try {
		try { deep(); } finally { log.push("f1"); }
	} catch (e) { log.push("caught " + (e as Error).message); }
}

function middle(): void {
	try { deep(); } finally { log.push("f2"); }
}

function outer(): void {
	try {
		try { middle(); } finally { log.push("f3"); }
	} catch (e) { log.push("caught mid"); }
}

function returns(): int32 {
	try { return 7; } finally { log.push("ret 7"); }
}

function late(n: int32): int32 {
	try { if (n > 0) throw new Error("late"); } finally { log.push("f4"); }
	return n;
}

sameFrame();
outer();
returns();
try { late(1); } catch (e) { log.push("caught " + (e as Error).message); }
log.push("end");
console.log(log.join("|"));
