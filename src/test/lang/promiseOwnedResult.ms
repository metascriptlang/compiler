// A promise whose payload the future owns (a string, a struct, an array) completes through the
// runtime's owned-result helper; the payload comes back out of the await unchanged.

interface PorPoint { x: int32; name: string; }

test "owned promise result: a string payload settles and reads back" {
	const p = new Promise<string>((resolve) => { resolve("x"); });
	const s = await p;
	assert s == "x";
}

test "owned promise result: a struct payload settles and reads back" {
	const p = new Promise<PorPoint>((resolve) => { resolve({ x: 3, name: "pt" }); });
	const v = await p;
	assert v.x == 3 && v.name == "pt";
}

test "owned promise result: an int64 payload settles and reads back" {
	const p = new Promise<int64>((resolve) => { resolve(41 as int64); });
	const n = await p;
	assert n == 41;
}
