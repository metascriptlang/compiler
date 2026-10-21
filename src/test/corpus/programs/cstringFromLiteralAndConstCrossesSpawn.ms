// @skip-js: a sync function awaits and strlen is an extern C function; JS has neither
// @stdout: literal 2600000
// @stdout: const 3800000
// A cstring taken from a string literal or a const bound to one points at storage that lives
// for the whole program, so a spawn thread may read it while the caller returns.
@include("string.h")
extern function strlen(a: cstring): int64;

const K = "const-literal-value";

function fromLiteral(): int32 {
	const c: cstring = "literal-value";
	const f = spawn(() => { let t: int32 = 0; for (let i = 0; i < 200000; i += 1) t = t + (strlen(c) as int32); return t; });
	return await f;
}

function fromConst(): int32 {
	const c: cstring = K;
	const f = spawn(() => { let t: int32 = 0; for (let i = 0; i < 200000; i += 1) t = t + (strlen(c) as int32); return t; });
	return await f;
}

console.log(`literal ${fromLiteral()}`);
console.log(`const ${fromConst()}`);
