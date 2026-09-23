// bug135 — explicit generic type args leaked across module boundaries.
//
// Symptom:    A generic call in one module supplied type arguments to an
//             unrelated generic call in another. Victim code was correct and
//             the error pointed into std:
//                 Return type mismatch in 'doRequestTls': expected
//                 Result<HttpResponse, HttpError>, got Result<number, unknown>
//
// Root cause: the parser kept explicit type args in a process-global table
//             keyed only by "line:col" — no module identity — and the lookup
//             GUESSED the '<' column from the callee when the node had none.

import "./bug135helper";

interface Bug135Err { msg: string; }

function bug135Fail(): Result<string, Bug135Err> {
	return Result.err({ msg: "leak" });
}

test "bug135: a sibling module's type args never reach this Result.err" {
	const r = bug135Fail();
	assert !r.ok;
	assert r.error.msg == "leak";
}

function bug135Ok(): Result<int32, Bug135Err> {
	const n: int32 = 3;
	return Result.ok(n);
}

test "bug135: a sibling module's new-expression type args never reach this Result.ok" {
	const r = bug135Ok();
	assert r.ok;
	assert r.value == 3;
}
