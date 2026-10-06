// Parity program — `Result.ok(v)` and `Result.err(e)` take T and E from the Result the context
// expects, so a converter reaches the value or the error, also from an enum member written in
// place, in a declaration, a return and an async return; a plain argument converts an enum member too.
//
// @stdout: arg 6000|member 6000|local 6001|ok 2|declared 6001|value 6001|async 6000
// @exit: 0

enum Fault { Zero, Big }
struct Code { code: uint64; }

converter faultCode(f: Fault): Code { return { code: (f as uint64) + 6000 }; }

function take(c: Code): uint64 { return c.code; }

function check(n: uint64): Result<uint64, Code> {
	if (n == 0) return Result.err(Fault.Zero);
	if (n == 1) {
		const f: Fault = Fault.Big;
		return Result.err(f);
	}
	return Result.ok(n);
}

function valued(): Result<Code, string> { return Result.ok(Fault.Big); }

async function later(n: uint64): Promise<Result<uint64, Code>> {
	if (n == 0) return Result.err(Fault.Zero);
	return Result.ok(n);
}

function codeOf(r: Result<uint64, Code>): uint64 { return r.ok ? r.value : r.error.code; }

const declared: Result<uint64, Code> = Result.err(Fault.Big);
const v = valued();
const a = await later(0);
console.log(`arg ${take(Fault.Zero)}|member ${codeOf(check(0))}|local ${codeOf(check(1))}|ok ${codeOf(check(2))}|declared ${codeOf(declared)}|value ${v.ok ? v.value.code : 0}|async ${codeOf(a)}`);
