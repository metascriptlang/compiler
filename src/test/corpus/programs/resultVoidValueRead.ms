// @stdout: true true 2 done
// note: reading .value of a Result<void, E> is the void value, never a field read

enum ProbeError { Failed }

function unwrap<T, E>(result: Result<T, E>): T {
	if (result.ok) { return result.value; }
	throw "failed";
}

function converted<T>(result: Result<T, int32>): Result<T, string> {
	if (!result.ok) { return Result.err("failed"); }
	return Result.ok(result.value);
}

function done(): Result<void, ProbeError> { return Result.ok(null); }
function doneInt(): Result<void, int32> { return Result.ok(null); }

let calls = 0;
function counted(): Result<void, ProbeError> { calls += 1; return Result.ok(null); }

unwrap(done());
const ran = converted(doneInt());
const direct = done();
let seen = false;
if (direct.ok) { const v = direct.value; seen = true; }
const timed = counted();
if (timed.ok) { const w = timed.value; calls += 1; }
console.log(`${ran.ok} ${seen} ${calls} done`);
