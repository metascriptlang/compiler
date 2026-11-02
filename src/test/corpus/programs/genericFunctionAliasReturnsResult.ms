// @stdout: ok|true|err no|pair 5
// @exit: 0
// note: a call through an instance of a generic function-type alias whose return is a large value (a Result, a tuple) passes the result slot the alias's function type declares: a class payload, a Vec of rule aliases over a struct error, a failing call, and a two-parameter alias returning a tuple.

class Box {
	v: int32;
	constructor(v: int32) {
		this.v = v;
	}
}

struct Failure {
	message: string;
}

type Parse<V> = (input: string) => Result<V, string>;
type Check<T> = (value: T) => Result<boolean, Failure>;
type Join<A, B> = (a: A, b: B) => [string, int32];

function parseBox(s: string): Result<Box, string> {
	return Result.ok(new Box(s.length));
}

function refuse(s: string): Result<Box, string> {
	return Result.err("no");
}

function positive(value: int32): Result<boolean, Failure> {
	return Result.ok(value > 0);
}

function joined(a: string, b: int32): [string, int32] {
	return [a, b + a.length];
}

function anyPasses(value: int32, rules: Vec<Check<int32>>): boolean {
	for (const rule of rules) {
		const seen = rule(value);
		if (seen.ok && seen.value) {
			return true;
		}
	}
	return false;
}

const p: Parse<Box> = parseBox;
const q: Parse<Box> = refuse;
const j: Join<string, int32> = joined;
const failed = q("x");
const pair = j("pair", 1);
console.log(`${p("abc").ok ? "ok" : "err"}|${anyPasses(3, [positive])}|${failed.ok ? "ok" : "err " + failed.error}|${pair[0]} ${pair[1]}`);
