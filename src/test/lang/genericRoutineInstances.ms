struct Pet { n: int32; }

function decode(this typeof Pet, seed: int32): Result<Pet, string> { return Result.ok({ n: seed }); }

function widen<T>(seed: int32): Result<int32, string> {
	return Result.ok(seed + (sizeof(T) as int32));
}

export function neverInstantiated<T>(seed: int32): Result<int32, string> {
	const value = try widen<T>(seed);
	return Result.ok(value);
}

function decodeWide<T>(seed: int32): Result<int32, string> {
	const v = try T.decode(seed);
	return Result.ok(v.n + (sizeof(T) as int32));
}

test "a generic whose type parameter is only in its body is checked per instance" {
	const r = widen<int64>(1);
	assert r.ok && r.value == 9;
}

test "a generic that trys a static of its type parameter binds the instance's type" {
	const r = decodeWide<Pet>(3);
	assert r.ok && r.value == 7;
}
