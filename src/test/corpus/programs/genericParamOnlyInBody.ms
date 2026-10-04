// @stdout: 9|7|11
// @exit: 0

// A generic routine whose type parameter appears only in its body emits one
// definition per instance and none for itself.

struct Pet { n: int32; }

function decode(this typeof Pet, seed: int32): Result<Pet, string> { return Result.ok({ n: seed }); }

function widen<T>(seed: int32): Result<int32, string> {
	return Result.ok(seed + (sizeof(T) as int32));
}

function chain<T>(seed: int32): Result<int32, string> {
	const value = try widen<T>(seed);
	return Result.ok(value);
}

function decodeWide<T>(seed: int32): Result<int32, string> {
	const v = try T.decode(seed);
	return Result.ok(v.n + (sizeof(T) as int32));
}

export function unused<T>(seed: int32): Result<int32, string> {
	const value = try widen<T>(seed);
	return Result.ok(value * 2);
}

const a = chain<int64>(1);
const b = decodeWide<Pet>(3);
const c = chain<Pet>(7);
console.log([a.ok ? String(a.value) : "err", b.ok ? String(b.value) : "err", c.ok ? String(c.value) : "err"].join("|"));
