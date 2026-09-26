// Symptom: an `await` inside a larger expression gave a wrong value or failed the C build.
//   `async function f() { const h = spawn(() => 41); return await h + 1; }` returned 1;
//   `return await g() + await h()` and `twice(await g())` failed clang. In sync code
//   `side() + await g()` ran `g` first, and `false && await g()` / `false ? await g() : 7` still ran `g`.
// Root cause: asyncDesugar split only `return await x`, so a YieldExpr nested in an expression
//   reached codegen, which printed a comment in its place; awaitLower hoisted every nested await
//   ahead of the whole statement, ignoring the operands before it and the short-circuit guards.
// Fix: awaitSpill runs before both, gives every await its own declaration, moves effectful operands
//   before it into temps in order, and puts an await under `&&` / `||` / `?:` inside the branch that owns it.
// Corpus sibling: src/test/corpus/programs/423-awaitInExpression.ms runs the same shapes through every lane.

let trace221 = "";

function side221(tag: string, v: int32): int32 {
	trace221 = trace221 + tag;
	return v;
}

async function val221(tag: string, v: int32): Promise<int32> {
	trace221 = trace221 + tag;
	return v;
}

async function flag221(tag: string, v: boolean): Promise<boolean> {
	trace221 = trace221 + tag;
	return v;
}

function twice221(n: int32): int32 {
	return n * 2;
}

function take221(): string {
	const t = trace221;
	trace221 = "";
	return t;
}

async function spawnPlusOne221(): Promise<int32> {
	const h = spawn(() => 41);
	return await h + 1;
}

async function twoAwaits221(): Promise<int32> {
	return await val221("g", 40) + await val221("h", 2);
}

async function awaitAsArg221(): Promise<int32> {
	return twice221(await val221("g", 21));
}

async function sideThenAwait221(): Promise<int32> {
	return side221("s", 1) + await val221("g", 41);
}

async function andSkipsAwait221(): Promise<boolean> {
	return false && await flag221("g", true);
}

async function ternarySkipsAwait221(): Promise<int32> {
	return false ? await val221("g", 1) : 7;
}

test "bug221: an awaited spawn handle is an operand in an async function" {
	assert await spawnPlusOne221() == 42;
}

test "bug221: two awaits in one async return expression" {
	assert await twoAwaits221() == 42;
	assert take221() == "gh";
}

test "bug221: an await is a call argument in an async function" {
	assert await awaitAsArg221() == 42;
	assert take221() == "g";
}

test "bug221: an operand before an await runs first in an async function" {
	assert await sideThenAwait221() == 42;
	assert take221() == "sg";
}

test "bug221: && skips its awaiting right operand in an async function" {
	assert !await andSkipsAwait221();
	assert take221() == "";
}

test "bug221: ?: skips its awaiting arm in an async function" {
	assert await ternarySkipsAwait221() == 7;
	assert take221() == "";
}

test "bug221: an operand before an await runs first in sync code" {
	const v = side221("s", 1) + await val221("g", 41);
	assert v == 42;
	assert take221() == "sg";
}

test "bug221: && skips its awaiting right operand in sync code" {
	const v = false && await flag221("g", true);
	assert !v;
	assert take221() == "";
}

test "bug221: ?: skips its awaiting arm in sync code" {
	const v = false ? await val221("g", 1) : 7;
	assert v == 7;
	assert take221() == "";
}
