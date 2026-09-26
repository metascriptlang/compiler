// nim-guard: an analyzer error names its line and column.
//
// Nim: injectdestructors.nim:358 and :522 report errFailedMove at the moved
// expression's info through localError (msgs.nim:648).
//
// RED MEANS the build and test paths print an analyzer error as
// '<path>: <message>' again, without the line the move sits on.
//
// GUARD-CHECK-FAIL cannot move 's'
// GUARD-CHECK-FAIL analyzerErrorLocation.ms:14:

function run(): void {
	const s = "k" + 1;
	const t = move s;
	console.log("t=" + t + " s=" + s);
}

run();
