// @stdout: true false|false|2|true
// note: an enum member passed where a type parameter is bound gives the parameter its enum, not
// the member's literal type. `Result.err(Failure.Rejected)` into `Result<uint64, Failure>` bound
// `E` to the literal and C emitted two Result structs; `pair(K.A, K.B)` and a reassigned
// `id(K.A)` were refused.

enum Failure { Rejected }
enum K { A, B }

const out: string[] = [];

function resultFor(value: uint32): Result<uint64, Failure> {
	if (value == 0) {
		const result: uint64 = 7;
		return Result.ok(result);
	}
	return Result.err(Failure.Rejected);
}

function rejected(): Result<uint64, Failure> {
	return Result.err(Failure.Rejected);
}

function id<T>(x: T): T { return x; }
function pair<T>(a: T, b: T): T[] { return [a, b]; }

out.push(`${resultFor(0).ok} ${resultFor(1).ok}`);
out.push(`${rejected().ok}`);
out.push(`${pair(K.A, K.B).length}`);
let k = id(K.A);
k = K.B;
out.push(`${k == K.B}`);
console.log(out.join("|"));
