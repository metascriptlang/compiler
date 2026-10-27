test "a function declared inside a function narrows by its predicate" {
	function isN(x: int32 | string): x is int32 { return typeof x == "number"; }
	const u: int32 | string = 5;
	assert (isN(u) ? u + 1 : 0) == 6, "narrowed to int32";
}

test "an assertion function declared inside a function narrows after the call" {
	function mustN(x: int32 | string): asserts x is int32 { if (typeof x != "number") throw new Error("not a number"); }
	const u: int32 | string = 7;
	mustN(u);
	assert u + 1 == 8, "narrowed to int32";
}

test "an arrow narrows by its predicate" {
	const isN = (x: int32 | string): x is int32 => typeof x == "number";
	const u: int32 | string = 5;
	assert (isN(u) ? u + 1 : 0) == 6, "narrowed to int32";
}

test "a function expression narrows by its predicate" {
	const isS = function (x: int32 | string): x is string { return typeof x == "string"; };
	const u: int32 | string = "ab";
	assert (isS(u) ? u.length : 0) == 2, "narrowed to string";
}

test "a function type carries its predicate" {
	const isN: (x: int32 | string) => x is int32 = (x: int32 | string): x is int32 => typeof x == "number";
	const u: int32 | string = 5;
	assert (isN(u) ? u + 1 : 0) == 6, "narrowed to int32";
}

function countNumbers(xs: (int32 | string)[], keep: (x: int32 | string) => x is int32): int32 {
	let sum = 0;
	for (const x of xs) if (keep(x)) sum += x;
	return sum;
}

test "a parameter typed with a predicate narrows inside the callee" {
	assert countNumbers([1, "a", 2], (x: int32 | string): x is int32 => typeof x == "number") == 3, "summed the numbers";
}

function mustS(x: int32 | string): asserts x is string {
	if (typeof x != "string") throw new Error("not a string");
}

function lengthOrNumber(v: int32 | string, check: boolean): int32 {
	if (check) {
		mustS(v);
		return v.length;
	}
	return typeof v == "number" ? v : 0;
}

test "an assertion narrows only the flow after its call" {
	assert lengthOrNumber("abc", true) == 3, "narrowed to string after the call";
	assert lengthOrNumber(4, false) == 4, "still the union on the other branch";
}
