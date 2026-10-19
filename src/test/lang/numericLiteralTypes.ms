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

test "number literal types: every literal beside a string is stored where it is read" {
	let k: 1 | 2 | string = "s";
	k = 2;
	assert k + 1 == 3;
	k = 1;
	assert k + 1 == 2;
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

function plusOne(v: 1 | 2 | string): int32 {
	if (typeof v === "number") return v + 1;
	return -1;
}
function bang(v: "a" | "b" | int32): string {
	if (typeof v === "string") return v + "!";
	return "-";
}
function asNumber(v: 1 | 2 | string): number {
	if (typeof v === "number") { const n: number = v; return n; }
	return -1;
}
function asString(v: "a" | "b" | int32): string {
	if (typeof v === "string") { const s: string = v; return s; }
	return "-";
}
function wrapNumbers(k: 1 | 2): 1 | 2 | string { return k; }
function wrapStrings(k: "a" | "b"): "a" | "b" | int32 { return k; }
function wrapNumbersOrNull(k: 1 | 2): 1 | 2 | string | null { return k; }
function wrapStringsOrNull(k: "a" | "b"): "a" | "b" | int32 | null { return k; }
function byEqualityNumber(v: 1 | 2 | string): int32 {
	if (v === 2) return v + 10;
	if (typeof v === "string") return 0;
	return v + 100;
}
function byEqualityString(v: "a" | "b" | int32): string {
	if (v === "b") return v + "!";
	if (typeof v === "number") return "n";
	return v + "?";
}
function bySet(p: 1 | 2): int32 {
	if (p === 2) { const q: 2 = p; return q * 10; }
	const r: 1 = p;
	return r;
}
function bySetString(p: "a" | "b"): string {
	if (p === "b") { const q: "b" = p; return q + "!"; }
	const r: "a" = p;
	return r;
}

test "number literal set narrowed by typeof reads as its number, as a string set reads as its string" {
	assert plusOne(2) == 3;
	assert plusOne("s") == -1;
	assert bang("b") == "b!";
	assert bang(3) == "-";
	assert asNumber(2) == 2;
	assert asString("a") == "a";
	const a = pick(1);
	if (typeof a === "number") assert a == 2;
	else assert false;
}

test "number literal set widens into a wider union as a string set does" {
	const a = wrapNumbers(2);
	assert typeof a == "number";
	assert a == 2;
	const b = wrapStrings("b");
	assert typeof b == "string";
	assert b == "b";
	const c = wrapNumbersOrNull(1);
	assert c != null && typeof c == "number";
	const d = wrapStringsOrNull("a");
	assert d != null && typeof d == "string";
}

test "equality against a literal narrows a literal union as it narrows a string union" {
	assert byEqualityNumber(2) == 12;
	assert byEqualityNumber(1) == 101;
	assert byEqualityNumber("x") == 0;
	assert byEqualityString("b") == "b!";
	assert byEqualityString("a") == "a?";
	assert byEqualityString(4) == "n";
	assert bySet(2) == 20;
	assert bySet(1) == 1;
	assert bySetString("b") == "b!";
	assert bySetString("a") == "a";
}

test "a number literal receiver is its base for toString, in text and with a radix" {
	const one: 1 = 1;
	assert one.toString() == "1";
	assert `${one}` == "1";
	const half: 1.5 = 1.5;
	assert half.toString() == "1.5";
	assert `${half}` == "1.5";
	const set: 1 | 2 = 2;
	assert set.toString() == "2";
	assert set.toString(2) == "10";
	assert `${set}` == "2";
	const mixed: 1 | 2.5 = 2.5;
	assert `${mixed}` == "2.5";
	const neg: -1 | 1 = -1;
	assert `${neg}` == "-1";
	const big: 3000000000 = 3000000000;
	assert big.toString(16) == "b2d05e00";
}
