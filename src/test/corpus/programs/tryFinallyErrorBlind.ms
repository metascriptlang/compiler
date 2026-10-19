// Parity program — a finally that cannot see the error flag runs without the save/clear/restore
// scaffold, and a finally that can see it keeps the scaffold: an exception in flight reaches its
// handler untouched by a cleanup that catches its own error.
//
// @stdout: f1|caught boom|f2|own caught|caught boom2|f3 raised|caught late|end
// @exit: 0

const log: string[] = [];

function boom(msg: string): void { throw new Error(msg); }

function ownCatch(): void {
	try { boom("inner"); } catch (e) { log.push("own caught"); }
}

function sameFrame(): void {
	try {
		try { boom("boom"); } finally { log.push("f1"); }
	} catch (e) { log.push("caught " + (e as Error).message); }
}

function cleanupWithOwnTry(): void {
	try {
		try { boom("boom2"); } finally { log.push("f2"); ownCatch(); }
	} catch (e) { log.push("caught " + (e as Error).message); }
}

function finallyRaises(): void {
	try {
		try { boom("first"); } finally { log.push("f3 raised"); boom("late"); }
	} catch (e) { log.push("caught " + (e as Error).message); }
}

sameFrame();
cleanupWithOwnTry();
finallyRaises();
log.push("end");
console.log(log.join("|"));
