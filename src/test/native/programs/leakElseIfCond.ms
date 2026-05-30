// FIXED (b3 audit) — a fresh RC call in an `else if` condition leaked per evaluation.
//
// An `else if` is the `.alternate` of its parent IfStmt, never a statement-list
// entry, so callHoist's expandStmt never reached its condition → the fresh Result
// in `else if (provide(i).ok)` was never cleaned (~277MB over 3M iterations).
//
// Fix: when an else-if chain holds a fresh-RC-call condition, callHoist wraps the
// else-if in a block so the walker descends and lowers it (cascading down the
// chain). Permanent regression guard — was leaking, now flat.

function provide(n: number): Result<string, string> {
	return Result.ok(`payload-${n}-xxxxxxxxxxxxxxxxxxxxxxxx`);
}

function main(): void {
	let hits = 0;
	let i = 0;
	while (i < 3000000) {
		if (i < 0) { hits = hits + 9; }
		else if (provide(i).ok) { hits = hits + 1; }
		i = i + 1;
	}
	console.log(`leak-elseif-cond hits=${hits}`);
}
main();
