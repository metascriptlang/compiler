// OPEN BUG (xfail) — fresh RC call result used for a non-RC read leaks.
//
// `provide(...)` returns Result<string,string> (heap-allocating). Reading only
// `.ok` (a bool) means the Result is never bound to an RC variable, so the
// analyzer's early-return on the non-RC LHS skips cleanup entirely → the Result
// (and its string payload) leak once per iteration. Same root cause in
// assignment RHS and in if/while conditions.
//
// Expected to LEAK until the Phase-3 call-hoist fix lands (rewrite to
// `const $t = provide(...); ... $t.ok`, matching Nim's nkStmtListExpr hoist in
// injectdestructors.nim). When fixed: drop the xfail in manifest.ts and this
// becomes a permanent regression guard.

function provide(path: string): Result<string, string> {
	if (path.length > 3) { return Result.ok(`content-${path}-padding-payload-bytes`); }
	return Result.err("no");
}

function main(): void {
	let hits = 0;
	let i = 0;
	while (i < 3000000) {
		const root = `dir-${i % 100}`;
		const has = provide(`${root}/file`).ok;   // fresh Result, only .ok read → leak
		if (has) { hits = hits + 1; }
		i = i + 1;
	}
	console.log(`leak-call-in-cond hits=${hits}`);
}
