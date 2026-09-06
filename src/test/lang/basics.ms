// Language tests: basics — arithmetic, comparison, boolean, strings, variables

function myAbs(n: number): number {
	if (n < 0) return -n;
	return n;
}

function clamp(n: number, lo: number, hi: number): number {
	if (n < lo) return lo;
	if (n > hi) return hi;
	return n;
}

function isDigit(ch: number): boolean {
	return ch >= "0".code && ch <= "9".code;
}

function isAlpha(ch: number): boolean {
	return (ch >= "a".code && ch <= "z".code) || (ch >= "A".code && ch <= "Z".code);
}

test "arithmetic" {
	assert 2 + 3 == 5;
	assert 10 - 4 == 6;
	assert 3 * 7 == 21;
	assert 15 / 3 == 5;
	assert 17 % 5 == 2;
}

test "comparison" {
	assert 3 < 5;
	assert 5 > 3;
	assert 3 <= 3;
	assert 5 >= 4;
	assert 3 != 4;
}

test "boolean" {
	assert true && true;
	assert !(true && false);
	assert true || false;
	assert !(false || false);
	assert !false;
}

test "strings" {
	assert "hello".length == 5;
	assert "".length == 0;
	assert "a" + "b" == "ab";
	assert "hello" == "hello";
	assert "hello" != "world";
}

test "variables" {
	const y = 42;
	assert y == 42;
	let x = 10;
	assert x == 10;
	x = 20;
	assert x == 20;
	x += 5;
	assert x == 25;
}

test "if/else" {
	assert myAbs(5) == 5;
	assert myAbs(-3) == 3;
	assert myAbs(0) == 0;
	assert clamp(5, 0, 10) == 5;
	assert clamp(-3, 0, 10) == 0;
	assert clamp(15, 0, 10) == 10;
}

test "ternary" {
	const sign = 5 > 0 ? "pos" : "neg";
	assert sign == "pos";
	const sign2 = -3 > 0 ? "pos" : "neg";
	assert sign2 == "neg";
}

test "char codes" {
	assert isDigit("5".code);
	assert !isDigit("a".code);
	assert isAlpha("m".code);
	assert !isAlpha("3".code);
}
