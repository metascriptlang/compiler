// @xfail(raiser): the Raiser bytecode compiler cannot compile a `try` in a match expression arm (inbox 2026-10-14-raiser-try-in-a-match-arm-cannot-compile)
// @stdout: ok 1 err neg err neg ok 0
function f(n: int32): Result<int32, string> { return n > 0 ? Result.ok(n) : Result.err("neg"); }
function g(k: int32): Result<int32, string> {
	return match (k) {
		1 => Result.ok(try f(k)),
		2 => Result.ok(try f(0 - k)),
		3 => match (k) { 3 => Result.ok(try f(0 - k)), _ => Result.ok(5) },
		_ => Result.ok(0),
	};
}
function show(r: Result<int32, string>): string { return r.ok ? "ok " + r.value.toString() : "err " + r.error; }
console.log(show(g(1)), show(g(2)), show(g(3)), show(g(9)));
