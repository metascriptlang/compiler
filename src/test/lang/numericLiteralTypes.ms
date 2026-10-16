type Small = { v: 1 | 2; t: uint8 };

function scale(k: 1 | 2): int32 { return k * 10; }
function pick(k: int32): 1 | 2 | string { return k > 0 ? 2 : "s"; }
function sign(positive: boolean): -1 | 1 { return positive ? 1 : -1; }

test "number literal types: a single literal annotation holds its value" {
	const x: 1 = 1;
	assert x == 1;
	const neg: -1 = -1;
	assert neg == -1;
	const half: 1.5 = 1.5;
	assert half == 1.5;
	const wide: 3000000000 = 3000000000;
	assert wide == 3000000000;
}

test "number literal types: a literal held beside a string reads as its number" {
	const k: 1 | 2 | string = 2;
	assert k + 1 == 3;
	assert k == 2;
	const m: 1 | 2.5 = 2.5;
	assert m + 1 == 3.5;
	const big: 3000000000 | string = 3000000000;
	assert big + 1 == 3000000001;
}

test "number literal types: 1 and 1.0 spell one value" {
	const whole: 1 = 1.0;
	assert whole == 1;
	const spelled: 1.0 = 1;
	assert spelled == 1;
	const mixed: 1 | 2.5 = 2.5;
	assert mixed == 2.5;
}

test "number literal types: a union of literals as a parameter, a return and a field" {
	assert scale(1) == 10;
	assert scale(2) == 20;
	assert sign(true) == 1;
	assert sign(false) == -1;
	const s: Small = { v: 1, t: 1 };
	assert s.v == 1 && s.t == 1;
	const l: -1 | 0 | 1 = -1;
	assert l == -1;
	const fractions: 0.5 | 1.5 = 0.5;
	assert fractions == 0.5;
}

test "number literal types: a literal beside a string in one union" {
	const a = pick(1);
	assert typeof a == "number";
	const w: 1 | 2 | string = 2;
	assert typeof w == "number";
	const b = pick(0);
	assert typeof b == "string";
}

test "number literal types: a literal-typed value is its base in arithmetic, comparison, switch and conversion" {
	const one: 1 = 1;
	assert one + 1 == 2;
	const asInt: int32 = one;
	const asFloat: float64 = one;
	const asBig: int64 = one;
	assert asInt == 1 && asFloat == 1.0 && asBig == 1;
	let v: 1 | 2 = 1;
	assert v == 1;
	v = 2;
	assert v != 1;
	let seen = "";
	switch (v) {
		case 1: seen = "one"; break;
		case 2: seen = "two"; break;
	}
	assert seen == "two";
}

test "number literal types: arrays and fields keep the literal element type" {
	const values: (1 | 2)[] = [1, 2, 2];
	let total = 0;
	for (const e of values) total += e;
	assert total == 5;
	const small: Small = { v: 2, t: 7 };
	assert small.v + small.t == 9;
}
