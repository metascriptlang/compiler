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

let trace228 = "";

function side228(tag: string, v: int32): int32 {
	trace228 = trace228 + tag;
	return v;
}

async function val228(tag: string, v: int32): Promise<int32> {
	trace228 = trace228 + tag;
	return v;
}

async function flag228(tag: string, v: boolean): Promise<boolean> {
	trace228 = trace228 + tag;
	return v;
}

function twice228(n: int32): int32 {
	return n * 2;
}

function take228(): string {
	const t = trace228;
	trace228 = "";
	return t;
}

async function spawnPlusOne228(): Promise<int32> {
	const h = spawn(() => 41);
	return await h + 1;
}

async function twoAwaits228(): Promise<int32> {
	return await val228("g", 40) + await val228("h", 2);
}

async function awaitAsArg228(): Promise<int32> {
	return twice228(await val228("g", 21));
}

async function sideThenAwait228(): Promise<int32> {
	return side228("s", 1) + await val228("g", 41);
}

async function andSkipsAwait228(): Promise<boolean> {
	return false && await flag228("g", true);
}

async function ternarySkipsAwait228(): Promise<int32> {
	return false ? await val228("g", 1) : 7;
}

test "bug228: an awaited spawn handle is an operand in an async function" {
	assert await spawnPlusOne228() == 42;
}

test "bug228: two awaits in one async return expression" {
	assert await twoAwaits228() == 42;
	assert take228() == "gh";
}

test "bug228: an await is a call argument in an async function" {
	assert await awaitAsArg228() == 42;
	assert take228() == "g";
}

test "bug228: an operand before an await runs first in an async function" {
	assert await sideThenAwait228() == 42;
	assert take228() == "sg";
}

test "bug228: && skips its awaiting right operand in an async function" {
	assert !await andSkipsAwait228();
	assert take228() == "";
}

test "bug228: ?: skips its awaiting arm in an async function" {
	assert await ternarySkipsAwait228() == 7;
	assert take228() == "";
}

test "bug228: an operand before an await runs first in sync code" {
	const v = side228("s", 1) + await val228("g", 41);
	assert v == 42;
	assert take228() == "sg";
}

test "bug228: && skips its awaiting right operand in sync code" {
	const v = false && await flag228("g", true);
	assert !v;
	assert take228() == "";
}

test "bug228: ?: skips its awaiting arm in sync code" {
	const v = false ? await val228("g", 1) : 7;
	assert v == 7;
	assert take228() == "";
}
