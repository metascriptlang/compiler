// Language tests: a comment between the tokens of a construct leaves its meaning unchanged

function isText(x: string | int32): /* c */ x is string {
	return typeof x === "string";
}

function isTextSecond(x: string | int32): x /* c */ is string {
	return typeof x === "string";
}

function isTextLine(x: string | int32): // c
	x is string {
	return typeof x === "string";
}

function mustBeText(x: string | int32): asserts /* c */ x is string {
	if (typeof x !== "string") throw new Error("not text");
}

function mustBeTextSecond(x: string | int32): asserts x /* c */ is string {
	if (typeof x !== "string") throw new Error("not text");
}

function mustBeTextLine(x: string | int32): asserts x // c
	is string {
	if (typeof x !== "string") throw new Error("not text");
}

test "type predicate: a comment before or inside `x is T`" {
	assert isText("a");
	assert !isText(1);
	assert isTextSecond("a");
	assert !isTextSecond(1);
	assert isTextLine("a");
	assert !isTextLine(1);
}

test "assertion predicate: a comment before the name, before `is`, or on a line of its own" {
	mustBeText("a");
	mustBeTextSecond("a");
	mustBeTextLine("a");
}

type MinusOne = - /* c */ 1;
type MinusTwo = -// c
	2;

test "negative literal type: a comment between the sign and the digits" {
	const a: MinusOne = -1;
	const b: MinusTwo = -2;
	assert a == -1;
	assert b == -2;
}

test "async function expression: a comment after `async`" {
	const f = async /* c */ function(): Promise<int32> { return 1; };
	const g = async // c
		function(): Promise<int32> { return 2; };
	assert typeof f == "function";
	assert typeof g == "function";
}

test "for-of: a comment between the binding and `of`, and after `of`" {
	const xs = [1, 2, 3];
	let sum = 0;
	for (const x /* c */ of xs) sum += x;
	for (const x of /* c */ xs) sum += x;
	for (const x // c
		of xs) sum += x;
	assert sum == 18;
}

const FromComptime: int32 = @ /* c */ comptime { return 7; };
const FromComptimeLine: int32 = @ // c
	comptime { return 8; };

test "comptime block: a comment between `@` and `comptime`" {
	assert FromComptime == 7;
	assert FromComptimeLine == 8;
}
