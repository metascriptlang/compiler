// bug187 — `try f();` in statement position failed to parse
// Symptom: `try record(graph, id);` inside a `Result<void, E>` function reported
//          "Parse: Expected '{'" — the only spelling that propagated a void Result was
//          binding the unit value (`const unused = try record(...)`).
// Root cause: the statement dispatcher sent every `try` token to the try/catch statement
//             parser, so the expression form never reached parseExprStmt, although
//             resultDesugar already lowers a standalone `try f();` ExprStmt.
// Fix: `try` opens a try/catch statement only when a block follows; otherwise the
//      statement is an expression statement.

const trail187: string[] = [];

function step187(name: string, ok: boolean): Result<void, string> {
	trail187.push(name);
	return ok ? Result.ok(null) : Result.err(name + " failed");
}

function both187(first: boolean, second: boolean): Result<void, string> {
	try step187("first", first);
	try step187("second", second);
	return Result.ok(null);
}

function guarded187(ok: boolean): Result<string, string> {
	if (ok) try step187("guard", true);
	else try step187("guard", false);
	return Result.ok("after");
}

test "a try statement continues after an ok void result" {
	trail187.length = 0;
	const r = both187(true, true);
	assert r.ok;
	assert trail187.length == 2;
}

test "a try statement returns the error and skips the rest" {
	trail187.length = 0;
	const r = both187(false, true);
	assert !r.ok;
	if (!r.ok) assert r.error == "first failed";
	assert trail187.length == 1;
}

test "a try statement as an unbraced if body propagates" {
	const good = guarded187(true);
	assert good.ok;
	if (good.ok) assert good.value == "after";
	const bad = guarded187(false);
	assert !bad.ok;
	if (!bad.ok) assert bad.error == "guard failed";
}
