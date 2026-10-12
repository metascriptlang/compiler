// @stdout: rows=41 wrong=0
// note: a `try` in a position that is not evaluated (ternary arm, `&&` / `||` / `??` operand, catch value, an `if` / `while` / `do while` / `for` condition after a short circuit, a call argument, a `match` expression arm, an awaited operand) runs its operand and returns its error only when that position is evaluated; the loop conditions run per iteration and the switch discriminant and match arm lower instead of reaching codegen. Each row prints only when it is wrong, with the number of operand calls it made.

let ran: int32 = 0;

function fail(): Result<int32, string> {
	ran += 1;
	return Result.err("no");
}

function good(): Result<int32, string> {
	ran += 1;
	return Result.ok(3);
}

async function failAsync(): Promise<Result<int32, string>> {
	ran += 1;
	return Result.err("no");
}

function add(a: int32, b: int32): int32 {
	return a + b;
}

function thenArm(f: int32): Result<int32, string> { const p = f != 0 ? try fail() : 7; return Result.ok(p); }
function elseArm(f: int32): Result<int32, string> { const p = f == 0 ? 7 : try fail(); return Result.ok(p); }
function andOperand(f: int32): Result<boolean, string> { const p = f != 0 && (try fail()) == 3; return Result.ok(p); }
function orOperand(f: int32): Result<boolean, string> { const p = f == 0 || (try fail()) == 3; return Result.ok(p); }
function coalesceOperand(f: int32): Result<int32, string> { const x: int32 | null = f == 0 ? 5 : null; const p = x ?? (try fail()); return Result.ok(p); }
function ifCondition(f: int32): Result<int32, string> { if (f != 0 && (try fail()) == 3) { return Result.ok(1); } return Result.ok(0); }
function elseIfCondition(f: int32): Result<int32, string> { if (f > 9) { return Result.ok(1); } else if ((try good()) == 3) { return Result.ok(2); } return Result.ok(0); }
function callArgument(f: int32): Result<int32, string> { const p = add(1, f != 0 && (try fail()) == 3 ? 1 : 2); return Result.ok(p); }
function returnedTernary(f: int32): Result<int32, string> { return Result.ok(f == 0 ? 7 : try fail()); }
function ternaryInAnd(f: int32): Result<boolean, string> { const p = f == 0 || (f > 5 ? (try fail()) == 1 : false); return Result.ok(p); }
function chainedTernary(f: int32): Result<int32, string> { const p = f > 5 ? 1 : f == 0 ? 7 : try fail(); return Result.ok(p); }
function catchValue(f: int32): Result<int32, string> { const p = try good() catch (try fail()); return Result.ok(p); }
function catchValueTaken(f: int32): Result<int32, string> { const p = try fail() catch (try fail()); return Result.ok(p); }
function ternaryCatch(f: int32): Result<int32, string> { const p = f == 0 ? 7 : (try fail() catch 5); return Result.ok(p); }
function whileCondition(f: int32): Result<int32, string> { let i = 0; while (f != 0 && (try fail()) == 3) { i += 1; } return Result.ok(i); }
function whileEachIteration(n: int32): Result<int32, string> { let i = 0; while ((try good()) == 3 && i < n) { i += 1; } return Result.ok(i); }
function whileFails(n: int32): Result<int32, string> { let i = 0; while (i < n || (try fail()) == 3) { i += 1; } return Result.ok(i); }
function doWhileCondition(f: int32): Result<int32, string> { let i = 0; do { i += 1; } while (f != 0 && (try fail()) == 3); return Result.ok(i); }
function forCondition(n: int32): Result<int32, string> { let i = 0; for (let k = 0; k < n && (try good()) == 3; k++) { i += 1; } return Result.ok(i); }
function forFails(n: int32): Result<int32, string> { let i = 0; for (let k = 0; k < n || (try fail()) == 3; k++) { i += 1; } return Result.ok(i); }
function switchDiscriminant(f: int32): Result<int32, string> { switch (try good()) { case 3: return Result.ok(f + 1); default: return Result.ok(0); } }
function matchArm(f: int32): Result<int32, string> { const p = match (f) { 0 => 7, _ => try fail() }; return Result.ok(p); }
function matchArmInTernary(f: int32): Result<int32, string> { const p = f == 0 ? (match (f) { 0 => 4, _ => 5 }) : 9; return Result.ok(p); }
function matchStatementArm(f: int32): Result<int32, string> { let p = 0; match (f) { 0 => { p = 7; }, _ => { p = try fail(); } }; return Result.ok(p); }
async function awaitInArm(f: int32): Promise<Result<int32, string>> { const p = f == 0 ? 7 : try await failAsync(); return Result.ok(p); }

let rows: int32 = 0;
let wrong: int32 = 0;

function show(name: string, ok: boolean, value: int32, want: string): void {
	const got = `${ok ? "ok" : "err"} ${value} ran=${ran}`;
	rows += 1;
	if (got != want) {
		wrong += 1;
		console.log(`WRONG ${name}: got ${got}, want ${want}`);
	}
	ran = 0;
}
function showInt(name: string, r: Result<int32, string>, want: string): void { show(name, r.ok, r.ok ? r.value : -1, want); }
function showBool(name: string, r: Result<boolean, string>, want: string): void { show(name, r.ok, r.ok ? (r.value ? 1 : 0) : -1, want); }

showInt("then arm skipped", thenArm(0), "ok 7 ran=0");
showInt("then arm taken", thenArm(1), "err -1 ran=1");
showInt("else arm skipped", elseArm(0), "ok 7 ran=0");
showInt("else arm taken", elseArm(1), "err -1 ran=1");
showBool("and skipped", andOperand(0), "ok 0 ran=0");
showBool("and taken", andOperand(1), "err -1 ran=1");
showBool("or skipped", orOperand(0), "ok 1 ran=0");
showBool("or taken", orOperand(1), "err -1 ran=1");
showInt("coalesce skipped", coalesceOperand(0), "ok 5 ran=0");
showInt("coalesce taken", coalesceOperand(1), "err -1 ran=1");
showInt("if skipped", ifCondition(0), "ok 0 ran=0");
showInt("if taken", ifCondition(1), "err -1 ran=1");
showInt("else if", elseIfCondition(0), "ok 2 ran=1");
showInt("call argument skipped", callArgument(0), "ok 3 ran=0");
showInt("call argument taken", callArgument(1), "err -1 ran=1");
showInt("returned ternary skipped", returnedTernary(0), "ok 7 ran=0");
showInt("returned ternary taken", returnedTernary(1), "err -1 ran=1");
showBool("ternary in or skipped", ternaryInAnd(0), "ok 1 ran=0");
showBool("ternary in or taken", ternaryInAnd(9), "err -1 ran=1");
showInt("chained ternary skipped", chainedTernary(0), "ok 7 ran=0");
showInt("chained ternary taken", chainedTernary(1), "err -1 ran=1");
showInt("catch value skipped", catchValue(0), "ok 3 ran=1");
showInt("catch value taken", catchValueTaken(0), "err -1 ran=2");
showInt("ternary catch skipped", ternaryCatch(0), "ok 7 ran=0");
showInt("ternary catch taken", ternaryCatch(1), "ok 5 ran=1");
showInt("while skipped", whileCondition(0), "ok 0 ran=0");
showInt("while taken", whileCondition(1), "err -1 ran=1");
showInt("while each iteration", whileEachIteration(3), "ok 3 ran=4");
showInt("while fails on later iteration", whileFails(2), "err -1 ran=1");
showInt("do while skipped", doWhileCondition(0), "ok 1 ran=0");
showInt("do while taken", doWhileCondition(1), "err -1 ran=1");
showInt("for each iteration", forCondition(2), "ok 2 ran=2");
showInt("for fails on later iteration", forFails(2), "err -1 ran=1");
showInt("switch discriminant", switchDiscriminant(4), "ok 5 ran=1");
showInt("match arm skipped", matchArm(0), "ok 7 ran=0");
showInt("match arm taken", matchArm(1), "err -1 ran=1");
showInt("match in ternary", matchArmInTernary(0), "ok 4 ran=0");
showInt("match statement arm skipped", matchStatementArm(0), "ok 7 ran=0");
showInt("match statement arm taken", matchStatementArm(1), "err -1 ran=1");

async function main(): Promise<void> {
	showInt("await arm skipped", await awaitInArm(0), "ok 7 ran=0");
	showInt("await arm taken", await awaitInArm(1), "err -1 ran=1");
	console.log(`rows=${rows} wrong=${wrong}`);
}
main();
